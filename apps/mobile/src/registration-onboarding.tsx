import type { ImapProvider } from '@private-email/mail-core/imap-setup';
import type {
  Registration,
  RegistrationScreen,
} from '@private-email/mail-core/registration';
import type { ReactNode } from 'react';

import { useState, useSyncExternalStore } from 'react';
import { ActivityIndicator, Platform, Text, View } from 'react-native';
import { ScreenStack } from 'react-native-screens';

import { BackScreen } from './back-navigation.tsx';
import { Button } from './design.tsx';
import { ImapForm } from './imap-setup.tsx';
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
export function SignedOutPage({
  screen,
  store,
}: {
  readonly screen: RegistrationScreen;
  readonly store: Registration;
}) {
  const { snapshot, busy, failed } = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
  );
  const { t } = useLocalization();
  const colors = usePalette();
  const [welcomed, setWelcomed] = useState(false);
  const notice = snapshot.kind === 'signed-out' ? snapshot.notice : undefined;
  const showSignIn = welcomed || notice !== undefined;
  if (!showSignIn && busy) {
    return (
      <View style={[styles.page, { backgroundColor: colors.surfaceContent }]}>
        <ActivityIndicator accessibilityLabel={t('registration.connecting')} />
      </View>
    );
  }
  const welcome = (
    <Welcome
      onContinue={() => {
        setWelcomed(true);
      }}
    />
  );
  const copy = notice === undefined ? undefined : screen.copy;
  const { actions } = screen;
  const signIn = (
    <SignIn
      title={copy?.title ?? t('onboarding.signIn.title')}
      description={copy?.description ?? t('onboarding.signIn.description')}
      onBack={
        notice === undefined
          ? () => {
              setWelcomed(false);
            }
          : undefined
      }
      actions={
        <>
          {actions.signIn.map(({ offer, provider, label }) => (
            <OnboardingAction
              key={`${offer}-${provider}`}
              disabled={busy}
              fill={provider === 'apple' ? 'apple' : 'quiet'}
              label={label}
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
        <Text
          accessibilityRole="alert"
          style={[styles.text, { color: colors.textPrimary }]}>
          {t('registration.setupFailed')}
        </Text>
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
  if (Platform.OS === 'ios' && !Platform.isPad) {
    return (
      <ScreenStack style={styles.page}>
        {notice === undefined ? (
          <BackScreen
            screenId="welcome"
            activityState={2}
            accessibilityElementsHidden={welcomed}
            headerConfig={{ hidden: true }}>
            {welcome}
          </BackScreen>
        ) : null}
        {showSignIn ? (
          <BackScreen
            screenId="sign-in"
            activityState={2}
            headerConfig={{ hidden: true }}
            gestureEnabled={notice === undefined}>
            {signIn}
          </BackScreen>
        ) : null}
      </ScreenStack>
    );
  }
  return showSignIn ? signIn : welcome;
}

// The first mailbox: each provider opens its authorization, or its IMAP form in place.
export function FirstMailbox({
  button,
  busy,
  microsoft,
  store,
}: {
  readonly button: (
    label: string,
    action: () => Promise<void>,
    fill?: 'accent',
  ) => ReactNode;
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
        primaryButton={(label, action) => button(label, action, 'accent')}
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
