import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type { NativeMailAssistance } from '@private-email/mail-core/assistance-enablement';
import type { NativeTranslation } from '@private-email/mail-core/translation';
import type { ReactNode } from 'react';
import type { TurboModule } from 'react-native';

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
import { Switch, TurboModuleRegistry, View } from 'react-native';

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
import { SettingsBlock, SettingsGroup, SettingsRow } from './settings.tsx';
import { usePalette } from './theme.ts';
import { TranslationContext } from './translation.tsx';

export { MailAssistanceContext } from './mail-assistance-lifetime.ts';

interface MailAssistanceModule extends TurboModule, NativeMailAssistance {}

const native = () =>
  TurboModuleRegistry.getEnforcing<MailAssistanceModule>('UnwiredRegistration');

// This device's Mail Assistance Enablement; a host without the native module has no account.
export const mailAssistance = createMailAssistanceEnablement({
  mailAssistance: () =>
    TurboModuleRegistry.get<MailAssistanceModule>(
      'UnwiredRegistration',
    )?.mailAssistance() ?? Promise.resolve({ owner: null, profiles: [] }),
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

function useEnabled(account: string | undefined, profile = defaultProfile) {
  const store = use(MailAssistanceContext);
  const enablement = useSyncExternalStore(
    store?.subscribe ?? noSubscription,
    () => store?.getSnapshot(),
  );
  return mailAssistanceEnabled(enablement, account, profile);
}

// Account settings and Drafts use Default consent until #647 supplies their ownership.
// Readers below apply their own Profile consent to the retained native engines.
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
  const enabled = useEnabled(account);
  const engines = useMemo(
    () => ({ account, assistance, translation }),
    [account, assistance, translation],
  );
  return (
    <MailAssistanceEnginesContext value={engines}>
      <AssistanceContext value={enabled ? assistance : undefined}>
        <TranslationContext value={enabled ? translation : undefined}>
          {children}
        </TranslationContext>
      </AssistanceContext>
    </MailAssistanceEnginesContext>
  );
}

// Readers use their window's Profile consent independently of Account settings and Drafts.
export function ReaderMailAssistanceGate({
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

// The account page's opt-in for this device.
export function MailAssistanceSettings({
  account,
  assistance,
  button,
}: {
  readonly account: string;
  readonly assistance: NativeAssistance;
  readonly button: SettingsButton;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const store = use(MailAssistanceContext);
  const enabled = useEnabled(account);
  const read = useSyncExternalStore(
    store?.subscribe ?? noSubscription,
    () => store?.getSnapshot()?.owner === account,
  );
  const saveState = useSyncExternalStore(
    store?.subscribe ?? noSubscription,
    () => store?.getSaveState() ?? 'idle',
  );
  if (store === undefined || !read) {
    return null;
  }
  return (
    <SettingsGroup
      title={t('mailAssistance.title')}
      accessory={<OnDeviceMarker label={t('settings.onDevice')} />}
      footer={t('mailAssistance.description')}>
      <SettingsRow
        title={t('mailAssistance.title')}
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
            accessibilityLabel={t('mailAssistance.title')}
            style={{ minHeight: 28 }}
            onValueChange={(on) => {
              void store.setEnabled(account, defaultProfile, on);
            }}
            trackColor={{ false: colors.fillTrack, true: colors.accentFill }}
            value={enabled}
          />
        </View>
      </SettingsRow>
      {saveState === 'failed' ? (
        <SettingsBlock>
          {button(t('mailAssistance.retrySave'), () =>
            store.retrySave(account),
          )}
        </SettingsBlock>
      ) : null}
      {enabled ? (
        <AssistanceAvailability
          key={account}
          account={account}
          assistance={assistance}
        />
      ) : null}
    </SettingsGroup>
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
