import type { GmailInbox } from '@private-email/mail-core/gmail-inbox';
import type { MailboxConnection } from '@private-email/mail-core/registration';
import type {
  RemoteContentPolicy,
  RemoteContentSettingsStore,
} from '@private-email/mail-core/remote-content';
import type { ReactNode } from 'react';

import { remoteContentPolicy } from '@private-email/mail-core/remote-content';
import { radius, spacing, typography } from '@private-email/mail-core/theme';
import {
  createContext,
  use,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  AccessibilityInfo,
  ActivityIndicator,
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
  // The approved warning row keeps the Mac inset and small type on iPhone and iPad.
  notSaved: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingLeft: 40,
    paddingRight: spacing.m,
    paddingBottom: 10,
  },
  notSavedText: {
    ...typography.macos.subheadline,
    flexShrink: 1,
  },
  clear: { flexDirection: 'row', alignItems: 'center', gap: spacing.s },
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

// One remote image policy. A choice storage refuses leaves the saved one in place and says so
// under the row until the next choice.
function PolicySetting({
  icon,
  title,
  label,
  setting,
  selected,
  choices,
  save,
}: {
  readonly icon: string;
  readonly title: string;
  // Names the setting for each button's accessibility label and for the refusal.
  readonly label: string;
  readonly setting: string;
  readonly selected: Choice;
  readonly choices: readonly Choice[];
  readonly save: (choice: Choice) => Promise<boolean>;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [refused, setRefused] = useState<symbol>();
  const change = useRef<symbol | undefined>(undefined);
  const notSaved = t('remoteContent.notSaved', {
    setting,
    choice: t(`remoteContent.policies.${selected}`),
  });
  // Announce the committed saved choice, once for the current refusal.
  useLayoutEffect(() => {
    if (refused !== undefined && change.current === refused) {
      change.current = undefined;
      AccessibilityInfo.announceForAccessibility(notSaved);
    }
  }, [refused, notSaved]);
  useLayoutEffect(
    () => () => {
      change.current = undefined;
    },
    [],
  );
  return (
    <>
      <PolicyRow
        icon={icon}
        title={title}>
        <PolicyChoice
          label={label}
          selected={selected}
          choices={choices}
          onChoose={(choice) => {
            const request = Symbol('remote-content-choice');
            change.current = request;
            setRefused(undefined);
            void (async () => {
              if (!(await save(choice)) && change.current === request) {
                setRefused(request);
              }
            })();
          }}
        />
      </PolicyRow>
      {refused === undefined ? null : (
        <View style={styles.notSaved}>
          <SFSymbol
            name="exclamationmark.triangle.fill"
            color={colors.statusWarning}
          />
          <Text style={[styles.notSavedText, { color: colors.textSecondary }]}>
            {notSaved}
          </Text>
        </View>
      )}
    </>
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
  const [clearing, setClearing] = useState(false);
  const [cleared, setCleared] = useState<boolean>();
  if (store === undefined || settings === undefined) {
    return null;
  }
  return (
    <SettingsGroup
      title={t('remoteContent.title')}
      footer={t('remoteContent.description')}>
      <PolicySetting
        icon="photo"
        title={t('settings.remoteContent')}
        label={t('remoteContent.device')}
        setting={t('settings.remoteContent')}
        selected={settings.policy}
        choices={['ask', 'never', 'always']}
        save={(choice) =>
          // The device's own choices offer no `device`.
          choice === 'device' ? Promise.resolve(true) : store.setPolicy(choice)
        }
      />
      {mailboxes.map(({ id, address }) => (
        <PolicySetting
          key={id}
          icon="at"
          title={address}
          label={t('remoteContent.mailbox', { address })}
          setting={t('remoteContent.mailbox', { address })}
          selected={settings.overrides[id] ?? 'device'}
          choices={['device', 'ask', 'never', 'always']}
          save={(choice) =>
            store.setOverride(id, choice === 'device' ? undefined : choice)
          }
        />
      ))}
      <SettingsRow
        title={t('settings.trackingPixels')}
        subtitle={t('settings.trackingPixelsDetail')}>
        <Text style={[styles.label, { color: colors.textSecondary }]}>
          {t('settings.alwaysBlocked')}
        </Text>
      </SettingsRow>
      <SettingsBlock>
        <View style={styles.clear}>
          {clearing ? (
            <ActivityIndicator
              size="small"
              color={colors.textSecondary}
            />
          ) : null}
          {button(
            t(clearing ? 'remoteContent.clearing' : 'remoteContent.clear'),
            async () => {
              setCleared(undefined);
              setClearing(true);
              const result = await store.clear();
              setClearing(false);
              setCleared(result);
            },
            { disabled: clearing },
          )}
        </View>
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
