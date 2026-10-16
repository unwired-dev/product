import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type { MailAssistanceEnablementStore } from '@private-email/mail-core/assistance-enablement';
import type {
  InboxChoice,
  MailboxConnection,
  Registration,
  RegistrationScreen,
} from '@private-email/mail-core/registration';
import type { RemoteContentSettingsStore } from '@private-email/mail-core/remote-content';
import type { NativeTranslation } from '@private-email/mail-core/translation';
import type { ReactNode } from 'react';

import { registrationScreen } from '@private-email/mail-core/registration';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import {
  Fragment,
  createContext,
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
} from 'react';
import { ActivityIndicator, AppState, ScrollView, View } from 'react-native';

import type { SettingsDestination } from './settings.tsx';

import { AccountPage } from './account-page.tsx';
import { AccountActions, AccountSettings } from './account-settings.tsx';
import { Button, Notice } from './design.tsx';
import { Label } from './label.tsx';
import { LanguageSelector } from './language-selector.tsx';
import { useLocalization } from './localization.ts';
import {
  MailAssistanceContext,
  MailAssistanceGate,
  mailAssistance as deviceMailAssistance,
} from './mail-assistance.tsx';
import { AssistanceContext, nativeAssistance } from './message-summary.tsx';
import { TrustCard } from './onboarding.tsx';
import { FirstMailbox, SignedOutPage } from './registration-onboarding.tsx';
import { registrationStyles as styles } from './registration-styles.ts';
import {
  microsoftMail,
  registration,
  remoteContent as deviceRemoteContent,
} from './registration.ts';
import { RemoteContentContext } from './remote-content.tsx';
import {
  AccountCard,
  SettingsBlock,
  SettingsGroup,
  SettingsWindow,
  settingsButton,
} from './settings.tsx';
import { usePalette } from './theme.ts';
import { TranslationContext, nativeTranslation } from './translation.tsx';

// The connected Inbox opens the account page and asks a mailbox's provider for permission again
// through this.
export const AccountContext = createContext<
  | Readonly<{
      // Every Mailbox Connection, including those waiting for authorization again.
      mailboxes: readonly MailboxConnection[];
      // Settings opens on the given destination, such as Email Accounts for a password.
      openAccount: (destination?: SettingsDestination) => void;
      authorizeMailbox: (connection: string) => Promise<void>;
      refreshInbox: (load: () => Promise<void>) => Promise<void>;
    }>
  | undefined
>(undefined);

export function RegistrationGate({
  children,
  store = registration,
  microsoft = microsoftMail(),
  preview = previewInbox,
  remoteContent = deviceRemoteContent,
  mailAssistance = deviceMailAssistance,
  assistance = nativeAssistance,
  translation = nativeTranslation,
}: {
  readonly children: ReactNode;
  readonly store?: Registration;
  // This build can authorize Microsoft mail.
  readonly microsoft?: boolean;
  readonly preview?: boolean;
  // The device's remote content policies, for the Inbox's readers and the account page.
  readonly remoteContent?: RemoteContentSettingsStore;
  // The device's Mail Assistance Enablement, which permits the model and Translation below.
  readonly mailAssistance?: MailAssistanceEnablementStore;
  readonly assistance?: NativeAssistance;
  readonly translation?: NativeTranslation;
}) {
  const registrationState = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
  );
  const { snapshot, busy, locked } = registrationState;
  const colors = usePalette();
  const { t } = useLocalization();
  // This window's choice between the account page and a connected Inbox outlasts status updates.
  const [choice, setChoice] = useState<InboxChoice>();
  // Where Settings opens when the Inbox asks for a destination.
  const [start, setStart] = useState<SettingsDestination>();
  const screen = registrationScreen(t, registrationState, choice);
  const { choices } = screen;
  // A choice the shared rule no longer applies is forgotten, so an earlier snapshot cannot revive it.
  if (screen.choice !== choice) {
    setChoice(screen.choice);
    setStart(undefined);
  }
  // Enablement belongs to an admitted Product Account that is not being removed; it is read again
  // whenever that changes, or when locked storage may have become readable.
  const assistanceAccount =
    snapshot.kind === 'signed-out' || snapshot.removalPending !== undefined
      ? undefined
      : snapshot.productAccountId;
  const assistanceScope = JSON.stringify([
    assistanceAccount,
    snapshot.kind === 'device-pending',
    locked === true,
  ]);
  useEffect(() => {
    if (!preview) {
      void mailAssistance.load(assistanceScope);
    }
  }, [preview, mailAssistance, assistanceScope]);
  const actions = useMemo(
    () => ({
      mailboxes: screen.mailboxes,
      openAccount: (destination?: SettingsDestination) => {
        if (choices !== undefined) {
          setStart(destination);
          setChoice(choices.account);
        }
      },
      authorizeMailbox: store.authorizeMailbox,
      refreshInbox: store.refreshInbox,
    }),
    [store, screen.mailboxes, choices],
  );
  useEffect(() => {
    if (preview) {
      return;
    }
    // The host restored at app start. Like the Inbox, restore on every activation, including after
    // protected storage unlocks.
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        void store.resume();
      }
    });
    return () => {
      subscription.remove();
    };
  }, [preview, store]);
  // The preview Inbox has no Product Account; its Mock Mail Session answers assistance.
  if (preview) {
    return (
      <AssistanceContext value={assistance}>
        <TranslationContext value={translation}>{children}</TranslationContext>
      </AssistanceContext>
    );
  }
  if (screen.destination === 'inbox') {
    return (
      <RemoteContentContext value={remoteContent}>
        <MailAssistanceContext value={mailAssistance}>
          <MailAssistanceGate
            account={assistanceAccount}
            assistance={assistance}
            translation={translation}>
            <AccountContext value={actions}>{children}</AccountContext>
          </MailAssistanceGate>
        </MailAssistanceContext>
      </RemoteContentContext>
    );
  }
  if (screen.destination === 'account') {
    return (
      <RemoteContentContext value={remoteContent}>
        <MailAssistanceContext value={mailAssistance}>
          <RegistrationPage
            assistance={assistance}
            microsoft={microsoft}
            screen={screen}
            start={start}
            store={store}
            onInbox={
              choices === undefined
                ? undefined
                : () => {
                    setChoice(choices.inbox);
                  }
            }
          />
        </MailAssistanceContext>
      </RemoteContentContext>
    );
  }
  return (
    <ScrollView
      contentContainerStyle={styles.scroll}
      style={[styles.page, { backgroundColor: colors.surfaceContent }]}>
      <View style={styles.content}>
        <TrustCard
          icon="lock.fill"
          title={t('locked.title')}
          description={t('locked.description')}>
          {busy ? (
            <ActivityIndicator
              accessibilityLabel={t('registration.connecting')}
            />
          ) : null}
        </TrustCard>
      </View>
    </ScrollView>
  );
}

// A connected Inbox's account page: Settings, one destination at a time.
function SettingsPage({
  assistance,
  microsoft,
  screen,
  start,
  store,
  onInbox,
}: {
  readonly assistance: NativeAssistance;
  readonly microsoft: boolean;
  readonly screen: RegistrationScreen;
  readonly start: SettingsDestination | undefined;
  readonly store: Registration;
  readonly onInbox: () => void;
}) {
  const { snapshot, busy, failed, removalFailure } = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
  );
  const colors = usePalette();
  const { t } = useLocalization();
  // An explicit Inbox request wins; otherwise Settings opens Account & Devices.
  const [destination, setDestination] = useState<SettingsDestination>(
    () => start ?? 'account',
  );
  const { copy, actions, identity } = screen;
  if (snapshot.kind === 'signed-out' || identity === undefined) {
    return null;
  }
  const button = settingsButton(busy);
  const signIn = actions.signIn.map(({ offer, provider, label }) => (
    <Fragment key={`${offer}-${provider}`}>
      {button(label, () => store.register(provider))}
    </Fragment>
  ));
  const name = identity.name ?? t('settings.productAccount');
  return (
    <AccountPage onInbox={onInbox}>
      <SettingsWindow
        account={name}
        destination={destination}
        onDestination={setDestination}
        accessory={
          <>
            {busy ? (
              <ActivityIndicator
                accessibilityLabel={t('registration.connecting')}
                size="small"
              />
            ) : null}
            <View style={styles.grow} />
            {button(t('registration.openInbox'), () => {
              onInbox();
              return Promise.resolve();
            })}
          </>
        }>
        {failed || signIn.length > 0 ? (
          <SettingsGroup>
            <SettingsBlock>
              {failed ? (
                <Label
                  accessibilityRole="alert"
                  style={[styles.text, { color: colors.textPrimary }]}>
                  {t('registration.setupFailed')}
                </Label>
              ) : null}
              {signIn}
              {actions.retry ? button(t('common.retry'), store.restore) : null}
            </SettingsBlock>
          </SettingsGroup>
        ) : null}
        {destination === 'account' ? (
          <>
            <AccountCard
              name={name}
              detail={identity.provider}
            />
            <SettingsGroup footer={copy.description} />
          </>
        ) : null}
        {destination === 'language' ? <LanguageSelector /> : null}
        {actions.settings ? (
          <AccountSettings
            assistance={assistance}
            button={button}
            destination={destination}
            microsoft={microsoft}
            screen={screen}
            store={store}
          />
        ) : null}
        {destination === 'account' ? (
          <AccountActions
            button={button}
            failure={removalFailure}
            pending={snapshot.removalPending}
            store={store}
          />
        ) : null}
      </SettingsWindow>
    </AccountPage>
  );
}

function RegistrationPage({
  assistance,
  microsoft,
  screen,
  start,
  store,
  onInbox,
}: {
  readonly assistance: NativeAssistance;
  readonly microsoft: boolean;
  readonly screen: RegistrationScreen;
  readonly start: SettingsDestination | undefined;
  readonly store: Registration;
  // Returns to the connected Inbox, when it can open.
  readonly onInbox: (() => void) | undefined;
}) {
  const { snapshot, busy, failed, removalFailure } = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
  );
  const colors = usePalette();
  const { t } = useLocalization();
  const { copy, actions } = screen;
  // A connected Inbox's account page is Settings.
  if (onInbox !== undefined && snapshot.kind !== 'signed-out') {
    return (
      <SettingsPage
        // Another Product Account starts Settings afresh, on its own pending setup.
        key={snapshot.productAccountId}
        assistance={assistance}
        microsoft={microsoft}
        screen={screen}
        start={start}
        store={store}
        onInbox={onInbox}
      />
    );
  }
  if (snapshot.kind === 'signed-out') {
    return (
      <SignedOutPage
        screen={screen}
        store={store}
      />
    );
  }
  // Setup actions are design push buttons; the account's Settings groups keep their own.
  const button = (
    label: string,
    action: () => Promise<void>,
    fill?: 'accent',
  ) => (
    <Button
      disabled={busy}
      fill={fill ?? 'quiet'}
      label={label}
      onPress={() => {
        void action();
      }}
    />
  );
  const groupButton = settingsButton(busy);
  // Microsoft's refusal usually means the organization has not approved Unwired Mail yet.
  const organizationApproval =
    snapshot.kind === 'mailbox-needed' &&
    snapshot.reason === 'microsoft-unavailable' &&
    snapshot.removalPending === undefined;
  return (
    <ScrollView
      contentContainerStyle={styles.scroll}
      style={[styles.page, { backgroundColor: colors.surfaceContent }]}>
      <View style={styles.content}>
        <Label
          accessibilityRole="header"
          style={[styles.title, { color: colors.textPrimary }]}>
          {copy.title}
        </Label>
        {organizationApproval ? (
          <Notice
            icon="building.2"
            iconColor={colors.statusWarning}
            message={copy.description}
          />
        ) : (
          <Label style={[styles.text, { color: colors.textSecondary }]}>
            {copy.description}
          </Label>
        )}
        {copy.account === undefined ? null : (
          <Label style={[styles.text, { color: colors.textSecondary }]}>
            {copy.account}
          </Label>
        )}
        {busy ? (
          <ActivityIndicator
            accessibilityLabel={t('registration.connecting')}
          />
        ) : null}
        {failed ? (
          <Label
            accessibilityRole="alert"
            style={[styles.text, { color: colors.textPrimary }]}>
            {t('registration.setupFailed')}
          </Label>
        ) : null}
        {actions.firstMailbox ? (
          <FirstMailbox
            button={button}
            busy={busy}
            microsoft={microsoft}
            store={store}
          />
        ) : null}
        {actions.signIn.map(({ offer, provider, label }) => (
          <Fragment key={`${offer}-${provider}`}>
            {button(label, () => store.register(provider))}
          </Fragment>
        ))}
        {actions.retry ? button(t('common.retry'), store.restore) : null}
        {actions.settings ? (
          <AccountSettings
            assistance={assistance}
            button={groupButton}
            microsoft={microsoft}
            screen={screen}
            store={store}
          />
        ) : null}
        <AccountActions
          button={groupButton}
          failure={removalFailure}
          pending={snapshot.removalPending}
          store={store}
        />
        <LanguageSelector />
      </View>
    </ScrollView>
  );
}
