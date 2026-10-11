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
  use,
  useLayoutEffect,
  useMemo,
  useRef,
  useSyncExternalStore,
} from 'react';
import { TurboModuleRegistry } from 'react-native';

import { Action } from './action.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import {
  MailAssistanceContext,
  useMailAssistanceLifetime,
} from './mail-assistance-lifetime.ts';
import { AssistanceContext } from './message-summary.tsx';
import { registrationStyles as styles } from './registration-styles.ts';
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

// shortcut: every Mailbox Connection belongs to the Default Profile until #647 enables more
// Profiles; then gate each reader and Draft by its connection's Profile.
const profile = defaultProfile;

const noSubscription = () => () => undefined;

function useEnabled(account: string | undefined) {
  const store = use(MailAssistanceContext);
  const enablement = useSyncExternalStore(
    store?.subscribe ?? noSubscription,
    () => store?.getSnapshot(),
  );
  return mailAssistanceEnabled(enablement, account, profile);
}

// Supplies the on-device model and Translation only while `account` enabled assistance on this
// device. Turning it off unmounts every assistance panel, which cancels its request and forgets its
// preview; turning it on starts nothing.
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
  return (
    <AssistanceContext value={enabled ? assistance : undefined}>
      <TranslationContext value={enabled ? translation : undefined}>
        {children}
      </TranslationContext>
    </AssistanceContext>
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
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
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
    <>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {t('mailAssistance.title')}
      </Label>
      <Label style={[styles.text, { color: colors.secondary }]}>
        {t('mailAssistance.description')}
      </Label>
      <Label style={[styles.text, { color: colors.foreground }]}>
        {t(enabled ? 'mailAssistance.on' : 'mailAssistance.off')}
      </Label>
      {button(
        t(enabled ? 'mailAssistance.turnOff' : 'mailAssistance.turnOn'),
        () => store.setEnabled(account, profile, !enabled),
      )}
      {saveState === 'idle' ? null : (
        <Label style={[styles.text, { color: colors.secondary }]}>
          {t(
            saveState === 'saving'
              ? 'mailAssistance.saving'
              : 'mailAssistance.saveFailed',
          )}
        </Label>
      )}
      {saveState === 'failed'
        ? button(t('mailAssistance.retrySave'), () => store.retrySave(account))
        : null}
      {enabled ? (
        <AssistanceAvailability
          key={account}
          account={account}
          assistance={assistance}
        />
      ) : null}
    </>
  );
}

function AssistanceAvailability({
  account,
  assistance,
}: {
  readonly account: string;
  readonly assistance: NativeAssistance;
}) {
  const colors = usePalette();
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
  return (
    <>
      {state.kind === 'idle' ? null : (
        <Label style={[styles.text, { color: colors.secondary }]}>
          {state.kind === 'unavailable'
            ? t(
                state.reason === 'model-not-ready'
                  ? 'summary.model-not-ready'
                  : `mailAssistance.${state.reason}`,
              )
            : t(
                `mailAssistance.${state.kind === 'checking' || state.kind === 'available' ? state.kind : 'checkFailed'}`,
              )}
        </Label>
      )}
      <Action
        label={t('mailAssistance.checkAvailability')}
        onPress={() => {
          if (committed.current === check && enabled()) {
            void check.start(account);
          }
        }}
      />
    </>
  );
}
