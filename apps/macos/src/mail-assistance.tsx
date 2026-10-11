import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type { NativeMailAssistance } from '@private-email/mail-core/assistance-enablement';
import type { NativeTranslation } from '@private-email/mail-core/translation';
import type { ReactNode } from 'react';
import type { TurboModule } from 'react-native';

import {
  createMailAssistanceEnablement,
  mailAssistanceEnabled,
} from '@private-email/mail-core/assistance-enablement';
import { defaultProfile } from '@private-email/mail-core/registration';
import { use, useSyncExternalStore } from 'react';
import { TurboModuleRegistry } from 'react-native';

import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { MailAssistanceContext } from './mail-assistance-lifetime.ts';
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
  button,
}: {
  readonly account: string;
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
    </>
  );
}
