import type { ImapProvider } from '@private-email/mail-core/imap-setup';
import type { Registration } from '@private-email/mail-core/registration';
import type { ComponentProps } from 'react';

import {
  providerName,
  registrationActions,
  registrationCopy,
} from '@private-email/mail-core/registration';
import { useState, useSyncExternalStore } from 'react';
import { ActivityIndicator } from 'react-native';

import { Button } from './design.tsx';
import { ImapForm } from './imap-setup.tsx';
import { Label } from './label.tsx';
import { LanguageSelector } from './language-selector.tsx';
import { useLocalization } from './localization.ts';
import {
  FinePrint,
  OnboardingAction,
  ProviderList,
  ProviderRow,
  SignIn,
  Welcome,
} from './onboarding.tsx';
import { registrationStyles as styles } from './registration-styles.ts';
import { usePalette } from './theme.ts';

// Before a Product Account: Welcome, then Sign In. A notice about a removed device or account
// opens Sign In directly with that notice.
export function SignedOutPage({ store }: { readonly store: Registration }) {
  const { snapshot, busy, failed } = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
  );
  const { t } = useLocalization();
  const colors = usePalette();
  const [welcomed, setWelcomed] = useState(false);
  const notice = snapshot.kind === 'signed-out' ? snapshot.notice : undefined;
  if (notice === undefined && !welcomed) {
    return (
      <Welcome
        onContinue={() => {
          setWelcomed(true);
        }}
      />
    );
  }
  const copy = notice === undefined ? undefined : registrationCopy(t, snapshot);
  const actions = registrationActions(snapshot, failed);
  return (
    <SignIn
      title={copy?.title ?? t('onboarding.signIn.title')}
      description={copy?.description ?? t('onboarding.signIn.description')}
      actions={
        <>
          {actions.signIn.map(({ offer, provider }) => (
            <OnboardingAction
              key={`${offer}-${provider}`}
              disabled={busy}
              fill={provider === 'apple' ? 'apple' : 'quiet'}
              label={t(`registration.${offer}`, {
                provider: providerName(t, provider),
              })}
              onPress={() => {
                void store.register(provider);
              }}
            />
          ))}
          <FinePrint>{t('onboarding.signIn.finePrint')}</FinePrint>
        </>
      }>
      {busy ? (
        <ActivityIndicator accessibilityLabel={t('registration.connecting')} />
      ) : null}
      {failed ? (
        <Label
          accessibilityRole="alert"
          style={[styles.text, { color: colors.textPrimary }]}>
          {t('registration.setupFailed')}
        </Label>
      ) : null}
      {actions.retry ? (
        <Button
          disabled={busy}
          label={t('common.retry')}
          onPress={() => {
            void store.restore();
          }}
        />
      ) : null}
      <LanguageSelector />
    </SignIn>
  );
}

// The first mailbox: each provider opens its authorization, or its IMAP form in place.
export function FirstMailbox({
  button,
  busy,
  microsoft,
  store,
}: {
  readonly button: ComponentProps<typeof ImapForm>['button'];
  readonly busy: boolean;
  readonly microsoft: boolean;
  readonly store: Registration;
}) {
  const { t } = useLocalization();
  const [imap, setImap] = useState<ImapProvider>();
  if (imap !== undefined) {
    return (
      <ImapForm
        button={button}
        onCancel={() => {
          setImap(undefined);
        }}
        onConnected={undefined}
        provider={imap}
        repair={undefined}
        store={store}
      />
    );
  }
  const authorize = (provider: 'gmail' | 'microsoft-graph') => () => {
    void store.addMailbox(provider);
  };
  const imapRow = (provider: ImapProvider) => () => {
    setImap(provider);
  };
  const rows: Array<{
    key: 'gmail' | 'icloud' | 'microsoft' | 'fastmail' | 'other';
    letter: string;
    onPress: () => void;
  }> = [
    { key: 'gmail', letter: 'G', onPress: authorize('gmail') },
    { key: 'icloud', letter: 'i', onPress: imapRow('icloud') },
  ];
  if (microsoft) {
    rows.push({
      key: 'microsoft',
      letter: 'M',
      onPress: authorize('microsoft-graph'),
    });
  }
  rows.push(
    { key: 'fastmail', letter: 'F', onPress: imapRow('fastmail') },
    { key: 'other', letter: '@', onPress: imapRow('other') },
  );
  return (
    <>
      <ProviderList>
        {rows.map(({ key, letter, onPress }, index) => (
          <ProviderRow
            key={key}
            detail={t(`onboarding.providers.${key}.detail`)}
            disabled={busy}
            last={index === rows.length - 1}
            letter={letter}
            name={t(`onboarding.providers.${key}.name`)}
            onPress={onPress}
          />
        ))}
      </ProviderList>
      {button(t('registration.chooseMailbox'), () =>
        store.addMailbox('gmail', true),
      )}
    </>
  );
}
