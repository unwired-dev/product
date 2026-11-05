import type {
  NativeAssistance,
  NativePrivateCloud,
} from '@private-email/mail-core/assistance';
import type { MailProfile } from '@private-email/mail-core/registration';
import type { NativeTranslation } from '@private-email/mail-core/translation';
import type { ReactNode } from 'react';

import {
  createAssistanceAvailability,
  createPrivateCloudReadiness,
} from '@private-email/mail-core/assistance';
import {
  createMailAssistanceEnablement,
  mailAssistanceEnabled,
  privateCloudEnabled,
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
import { ActivityIndicator, Switch, View } from 'react-native';

import type { SettingsButton } from './settings.tsx';

import { Action } from './action.tsx';
import { askInSheet, OnDeviceMarker } from './design.tsx';
import { useLocalization } from './localization.ts';
import {
  MailAssistanceContext,
  MailAssistanceProfileContext,
  useMailAssistanceLifetime,
} from './mail-assistance-lifetime.ts';
import { AssistanceContext, nativePrivateCloud } from './message-summary.tsx';
import { native } from './registration.ts';
import { SettingsBlock, SettingsGroup, SettingsRow } from './settings.tsx';
import { usePalette } from './theme.ts';
import { TranslationContext } from './translation.tsx';

export { MailAssistanceContext } from './mail-assistance-lifetime.ts';

// This device's Mail Assistance Enablement.
export const mailAssistance = createMailAssistanceEnablement({
  mailAssistance: () => native().mailAssistance(),
  setMailAssistance: (owner, profiles, privateCloud) =>
    native().setMailAssistance(owner, profiles, privateCloud),
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

const device = 'mac';

// The account page's opt-in for this device: one switch for each Mail Profile, as each Profile
// gives its own consent, and then each Profile's separate Private Cloud choice.
export function MailAssistanceSettings({
  account,
  assistance,
  button,
  privateCloud = nativePrivateCloud,
  profiles,
}: {
  readonly account: string;
  readonly assistance: NativeAssistance;
  readonly button: SettingsButton;
  readonly privateCloud?: NativePrivateCloud;
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
    <>
      <SettingsGroup
        title={t('mailAssistance.title')}
        accessory={
          <OnDeviceMarker
            compact
            label={t('settings.onDevice')}
          />
        }
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
          <MailAssistanceProfileContext
            key={enabled}
            value={enabled}>
            <AssistanceAvailability
              key={account}
              account={account}
              assistance={assistance}
            />
          </MailAssistanceProfileContext>
        )}
      </SettingsGroup>
      <SettingsGroup
        title={t('privateCloud.title')}
        footer={t('privateCloud.footer', {
          device: t('privateCloud.device', { context: device }),
        })}>
        {[{ id: defaultProfile, name: t('profiles.primary') }, ...profiles].map(
          ({ id, name }) => (
            <MailAssistanceProfileContext
              key={id}
              value={id}>
              <PrivateCloudChoice
                key={account}
                account={account}
                name={name}
                privateCloud={privateCloud}
                saveState={saveState}
                titled={id !== defaultProfile}
              />
            </MailAssistanceProfileContext>
          ),
        )}
      </SettingsGroup>
    </>
  );
}

// One Mail Profile's Private Cloud consent, confirmed before it turns on, and its explicit
// readiness check. Neither opening Settings nor turning it on checks or generates anything.
function PrivateCloudChoice({
  account,
  name,
  privateCloud,
  saveState,
  titled,
}: {
  readonly account: string;
  readonly name: string;
  readonly privateCloud: NativePrivateCloud;
  readonly saveState: 'idle' | 'saving' | 'failed';
  // The Default Profile's switch carries the section's own title.
  readonly titled: boolean;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const store = use(MailAssistanceContext);
  const profile = use(MailAssistanceProfileContext);
  const assisted = useEnabled(account, profile);
  const enablement = useSyncExternalStore(
    store?.subscribe ?? noSubscription,
    () => store?.getSnapshot(),
  );
  const enabled = privateCloudEnabled(enablement, account, profile);
  const anchor = useRef<View>(null);
  const asked = useRef<ReturnType<typeof askInSheet>>(undefined);
  useLayoutEffect(
    () => () => {
      asked.current?.retire();
      asked.current = undefined;
    },
    [],
  );
  const failed = store?.getFailedSave();
  // Turning it on failed: it stays off, without the switch claiming otherwise.
  const unsaved =
    saveState === 'failed' &&
    failed?.choice === 'privateCloud' &&
    failed.enabled &&
    failed.profile === profile;
  const named = {
    profile: name,
    device: t('privateCloud.device', { context: device }),
  };
  if (store === undefined) {
    return null;
  }
  const subtitle = () => {
    if (!assisted) {
      return t('privateCloud.needsAssistance');
    }
    if (unsaved) {
      return t('privateCloud.saveFailed');
    }
    if (saveState === 'saving') {
      return t('mailAssistance.saving');
    }
    return t(enabled ? 'privateCloud.on' : 'privateCloud.off', named);
  };
  // Turn On is the sheet's default button; leaving Settings closes the sheet unanswered.
  const turnOn = async () => {
    asked.current?.retire();
    const question = askInSheet(anchor.current, {
      title: t('privateCloud.confirmTitle', named),
      detail: t('privateCloud.confirmMessage', named),
      buttons: [t('privateCloud.turnOn'), t('common.cancel')],
    });
    asked.current = question;
    if ((await question.answer) === 0 && asked.current === question) {
      await store.setPrivateCloud(account, profile, true);
    }
  };
  return (
    <>
      <SettingsRow
        title={titled ? name : t('privateCloud.use')}
        subtitle={subtitle()}
        subtitleTone={assisted && unsaved ? 'warning' : undefined}
        disabled={!assisted}>
        <View
          ref={anchor}
          style={{ minHeight: 28, justifyContent: 'center' }}>
          <Switch
            accessibilityLabel={
              titled
                ? t('privateCloud.profile', { name })
                : t('privateCloud.use')
            }
            disabled={!assisted}
            style={{ minHeight: 28 }}
            onValueChange={(on) => {
              if (on) {
                void turnOn();
              } else {
                void store.setPrivateCloud(account, profile, false);
              }
            }}
            trackColor={{ false: colors.fillTrack, true: colors.accentFill }}
            value={enabled}
          />
        </View>
      </SettingsRow>
      {enabled ? (
        <PrivateCloudReadiness
          account={account}
          named={named}
          privateCloud={privateCloud}
        />
      ) : null}
    </>
  );
}

function PrivateCloudReadiness({
  account,
  named,
  privateCloud,
}: {
  readonly account: string;
  readonly named: Readonly<{ profile: string; device: string }>;
  readonly privateCloud: NativePrivateCloud;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const profile = use(MailAssistanceProfileContext);
  const check = useMemo(
    () => createPrivateCloudReadiness(privateCloud),
    [privateCloud],
  );
  const enabled = useMailAssistanceLifetime(check.discard, privateCloudEnabled);
  const committed = useRef<typeof check>(undefined);
  useLayoutEffect(() => {
    committed.current = check;
    return () => {
      committed.current = undefined;
      check.discard();
    };
  }, [check]);
  const input = JSON.stringify([account, profile]);
  const state = useSyncExternalStore(check.subscribe, () =>
    check.getSnapshot(input),
  );
  const subtitle = () => {
    if (state.kind !== 'checked') {
      return t(
        state.kind === 'checking'
          ? 'privateCloud.checking'
          : 'privateCloud.notChecked',
      );
    }
    // The Mac frames word these two for the Mac.
    return state.readiness === 'limit-reached' ||
      state.readiness === 'device-ineligible'
      ? t(`privateCloud.${state.readiness}`, { ...named, context: 'mac' })
      : t(`privateCloud.${state.readiness}`, named);
  };
  return (
    <SettingsRow
      title={t('privateCloud.readiness')}
      subtitle={subtitle()}>
      {state.kind === 'checking' ? (
        <ActivityIndicator
          size="small"
          color={colors.textSecondary}
        />
      ) : (
        <Action
          label={t(
            state.kind === 'checked'
              ? 'privateCloud.checkAgain'
              : 'privateCloud.check',
          )}
          accessibilityLabel={t('privateCloud.readinessLabel', named)}
          onPress={() => {
            if (committed.current === check && enabled()) {
              void check.start(input);
            }
          }}
        />
      )}
    </SettingsRow>
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
