import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type { MailProfile } from '@private-email/mail-core/registration';
import type { NativeTranslation } from '@private-email/mail-core/translation';
import type { ReactNode } from 'react';

import { createAssistanceAvailability } from '@private-email/mail-core/assistance';
import {
  createMailAssistanceEnablement,
  mailAssistanceEnabled,
} from '@private-email/mail-core/assistance-enablement';
import { defaultProfile } from '@private-email/mail-core/registration';
import {
  createContext,
  use,
  useLayoutEffect,
  useMemo,
  useRef,
  useSyncExternalStore,
} from 'react';
import { Switch, View } from 'react-native';

import type { SettingsButton } from './settings.tsx';

import { Action } from './action.tsx';
import { OnDeviceMarker } from './design.tsx';
import { useLocalization } from './localization.ts';
import {
  MailAssistanceContext,
  MailAssistanceProfileContext,
  useMailAssistanceLifetime,
} from './mail-assistance-lifetime.ts';
import { AssistanceContext } from './message-summary.tsx';
import { native } from './registration.ts';
import { SettingsBlock, SettingsGroup, SettingsRow } from './settings.tsx';
import { usePalette } from './theme.ts';
import { TranslationContext } from './translation.tsx';

export { MailAssistanceContext } from './mail-assistance-lifetime.ts';

// This device's Mail Assistance Enablement.
export const mailAssistance = createMailAssistanceEnablement({
  mailAssistance: () => native().mailAssistance(),
  setMailAssistance: (owner, profiles) =>
    native().setMailAssistance(owner, profiles),
});

const noSubscription = () => () => undefined;

const MailAssistanceEnginesContext = createContext<
  | Readonly<{
      account: string | undefined;
      assistance: NativeAssistance;
      translation: NativeTranslation;
    }>
  | undefined
>(undefined);

function useEnabled(account: string | undefined, profile: string) {
  const store = use(MailAssistanceContext);
  const enablement = useSyncExternalStore(
    store?.subscribe ?? noSubscription,
    () => store?.getSnapshot(),
  );
  return mailAssistanceEnabled(enablement, account, profile);
}

// The retained native engines. Nothing at this level runs Mail Assistance: readers and Drafts
// enable them with their own Profile's consent.
export function MailAssistanceGate({
  account,
  assistance,
  translation,
  children,
}: {
  readonly account: string | undefined;
  readonly assistance: NativeAssistance;
  readonly translation: NativeTranslation;
  readonly children: ReactNode;
}) {
  const engines = useMemo(
    () => ({ account, assistance, translation }),
    [account, assistance, translation],
  );
  return (
    <MailAssistanceEnginesContext value={engines}>
      {children}
    </MailAssistanceEnginesContext>
  );
}

// A reader's window Profile or a Draft's owning Profile applies its own consent.
export function ProfileMailAssistanceGate({
  profile,
  children,
}: {
  readonly profile: string;
  readonly children: ReactNode;
}) {
  const engines = use(MailAssistanceEnginesContext);
  const enabled = useEnabled(engines?.account, profile);
  // Preview readers without a Product Account keep their supplied synthetic engines.
  if (engines === undefined) {
    return children;
  }
  return (
    <MailAssistanceProfileContext value={profile}>
      <AssistanceContext value={enabled ? engines.assistance : undefined}>
        <TranslationContext value={enabled ? engines.translation : undefined}>
          {children}
        </TranslationContext>
      </AssistanceContext>
    </MailAssistanceProfileContext>
  );
}

// The account page's opt-in for this device: one switch for each Mail Profile, as each Profile
// gives its own consent.
export function MailAssistanceSettings({
  account,
  assistance,
  button,
  profiles,
}: {
  readonly account: string;
  readonly assistance: NativeAssistance;
  readonly button: SettingsButton;
  // The Mail Profiles besides the Default Profile.
  readonly profiles: readonly MailProfile[];
}) {
  const { t } = useLocalization();
  const store = use(MailAssistanceContext);
  const enablement = useSyncExternalStore(
    store?.subscribe ?? noSubscription,
    () => store?.getSnapshot(),
  );
  const saveState = useSyncExternalStore(
    store?.subscribe ?? noSubscription,
    () => store?.getSaveState() ?? 'idle',
  );
  if (store === undefined || enablement?.owner !== account) {
    return null;
  }
  // Availability is checked while any Profile has opted in, within that Profile's consent.
  const enabled = [defaultProfile, ...profiles.map(({ id }) => id)].find(
    (profile) => mailAssistanceEnabled(enablement, account, profile),
  );
  return (
    <SettingsGroup
      title={t('mailAssistance.title')}
      accessory={<OnDeviceMarker label={t('settings.onDevice')} />}
      footer={t('mailAssistance.description')}>
      <ProfileSwitch
        account={account}
        label={t('mailAssistance.title')}
        profile={defaultProfile}
        saveState={saveState}
        title={t('mailAssistance.title')}
      />
      {profiles.map(({ id, name }) => (
        <ProfileSwitch
          key={id}
          account={account}
          label={t('mailAssistance.profile', { name })}
          profile={id}
          saveState={saveState}
          title={name}
        />
      ))}
      {saveState === 'failed' ? (
        <SettingsBlock>
          {button(t('mailAssistance.retrySave'), () =>
            store.retrySave(account),
          )}
        </SettingsBlock>
      ) : null}
      {enabled === undefined ? null : (
        <MailAssistanceProfileContext value={enabled}>
          <AssistanceAvailability
            key={account}
            account={account}
            assistance={assistance}
          />
        </MailAssistanceProfileContext>
      )}
    </SettingsGroup>
  );
}

// One Mail Profile's switch; the save state is shared by every Profile's choice.
function ProfileSwitch({
  account,
  label,
  profile,
  saveState,
  title,
}: {
  readonly account: string;
  readonly label: string;
  readonly profile: string;
  readonly saveState: 'idle' | 'saving' | 'failed';
  readonly title: string;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const store = use(MailAssistanceContext);
  const enabled = useEnabled(account, profile);
  if (store === undefined) {
    return null;
  }
  return (
    <SettingsRow
      title={title}
      subtitle={t(
        (
          {
            idle: enabled ? 'mailAssistance.on' : 'mailAssistance.off',
            saving: 'mailAssistance.saving',
            failed: 'mailAssistance.saveFailed',
          } as const
        )[saveState],
      )}>
      <View style={{ minHeight: 28, justifyContent: 'center' }}>
        <Switch
          accessibilityLabel={label}
          style={{ minHeight: 28 }}
          onValueChange={(on) => {
            void store.setEnabled(account, profile, on);
          }}
          trackColor={{ false: colors.fillTrack, true: colors.accentFill }}
          value={enabled}
        />
      </View>
    </SettingsRow>
  );
}

function AssistanceAvailability({
  account,
  assistance,
}: {
  readonly account: string;
  readonly assistance: NativeAssistance;
}) {
  const { t } = useLocalization();
  const check = useMemo(
    () => createAssistanceAvailability(assistance),
    [assistance],
  );
  const enabled = useMailAssistanceLifetime(check.discard);
  const committed = useRef<typeof check>(undefined);
  useLayoutEffect(() => {
    committed.current = check;
    return () => {
      committed.current = undefined;
      check.discard();
    };
  }, [check]);
  const state = useSyncExternalStore(check.subscribe, () =>
    check.getSnapshot(account),
  );
  const availability = () => {
    if (state.kind === 'idle') {
      return undefined;
    }
    if (state.kind === 'unavailable') {
      return t(
        state.reason === 'model-not-ready'
          ? 'summary.model-not-ready'
          : `mailAssistance.${state.reason}`,
      );
    }
    return t(
      `mailAssistance.${state.kind === 'checking' || state.kind === 'available' ? state.kind : 'checkFailed'}`,
    );
  };
  return (
    <SettingsRow
      title={t('settings.availability')}
      subtitle={availability()}>
      <Action
        label={t('mailAssistance.checkAvailability')}
        onPress={() => {
          if (committed.current === check && enabled()) {
            void check.start(account);
          }
        }}
      />
    </SettingsRow>
  );
}
