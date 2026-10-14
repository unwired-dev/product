import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type { MailAssistanceEnablementStore } from '@private-email/mail-core/assistance-enablement';
import type {
  InboxChoice,
  MailboxConnection,
  Registration,
} from '@private-email/mail-core/registration';
import type { RemoteContentSettingsStore } from '@private-email/mail-core/remote-content';
import type { NativeTranslation } from '@private-email/mail-core/translation';
import type { ReactNode } from 'react';

import {
  inboxLanding,
  inboxSetup,
  mailboxesOf,
  providerName,
  registrationActions,
  registrationCopy,
} from '@private-email/mail-core/registration';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import {
  Fragment,
  createContext,
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  ActivityIndicator,
  AppState,
  Pressable,
  ScrollView,
  Text,
  View,
} from 'react-native';

import type { SettingsDestination } from './settings.tsx';

import { AccountPage } from './account-page.tsx';
import { AccountActions, AccountSettings } from './account-settings.tsx';
import { Glass, SFSymbol } from './design.tsx';
import { ImapSetup } from './imap-setup.tsx';
import { LanguageSelector } from './language-selector.tsx';
import { useLocalization } from './localization.ts';
import {
  MailAssistanceContext,
  MailAssistanceGate,
  mailAssistance as deviceMailAssistance,
} from './mail-assistance.tsx';
import { AssistanceContext, nativeAssistance } from './message-summary.tsx';
import { registrationStyles as styles } from './registration-styles.ts';
import { microsoftMail, registration } from './registration.ts';
import {
  remoteContent as deviceRemoteContent,
  RemoteContentContext,
} from './remote-content.tsx';
import {
  AccountCard,
  SettingsBlock,
  SettingsGroup,
  SettingsWorkspace,
  settingsButton,
  settingsColumns,
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
  const { snapshot, busy, locked } = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
  );
  const colors = usePalette();
  const { t } = useLocalization();
  // The person's choice between the account page and a connected Inbox outlasts status updates.
  const [choice, setChoice] = useState<InboxChoice>();
  // Where Settings opens when the Inbox asks for a destination.
  const [start, setStart] = useState<SettingsDestination>();
  const landing = inboxLanding(snapshot, choice);
  const { account: inboxAccount, setup } = landing;
  if (choice !== undefined && !landing.valid) {
    setChoice(undefined);
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
      mailboxes: mailboxesOf(snapshot),
      openAccount: (destination?: SettingsDestination) => {
        if (inboxAccount !== undefined) {
          setStart(destination);
          setChoice({
            account: inboxAccount,
            destination: 'account',
            setup,
          });
        }
      },
      authorizeMailbox: store.authorizeMailbox,
      refreshInbox: store.refreshInbox,
    }),
    [store, snapshot, inboxAccount, setup],
  );
  useEffect(() => {
    if (preview) {
      return;
    }
    void store.restoreOnce();
    void remoteContent.load();
    // Like the Inbox, restore on every activation, including after protected storage unlocks.
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        void store.resume();
      }
    });
    return () => {
      subscription.remove();
    };
  }, [preview, store, remoteContent]);
  // The preview Inbox has no Product Account; its Mock Mail Session answers assistance.
  if (preview) {
    return (
      <AssistanceContext value={assistance}>
        <TranslationContext value={translation}>{children}</TranslationContext>
      </AssistanceContext>
    );
  }
  const inbox = landing.destination === 'inbox';
  if (!locked && inbox) {
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
  if (!locked) {
    return (
      <RemoteContentContext value={remoteContent}>
        <MailAssistanceContext value={mailAssistance}>
          <RegistrationPage
            assistance={assistance}
            microsoft={microsoft}
            start={start}
            store={store}
            onInbox={
              inboxAccount === undefined
                ? undefined
                : () => {
                    setChoice({
                      account: inboxAccount,
                      destination: 'inbox',
                      setup,
                    });
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
        <Text
          accessibilityRole="header"
          style={[styles.title, { color: colors.textPrimary }]}>
          {t('locked.title')}
        </Text>
        <Text style={[styles.text, { color: colors.textSecondary }]}>
          {t('locked.description')}
        </Text>
        {busy ? (
          <ActivityIndicator
            accessibilityLabel={t('registration.connecting')}
          />
        ) : null}
      </View>
    </ScrollView>
  );
}

// A connected Inbox's account page: Settings, one destination at a time.
function SettingsPage({
  assistance,
  microsoft,
  start,
  store,
  onInbox,
}: {
  readonly assistance: NativeAssistance;
  readonly microsoft: boolean;
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
  // An explicit Inbox request wins; otherwise pending setup opens Account & Devices,
  // then iPad's first destination or iPhone's list of them.
  const [destination, setDestination] = useState<
    SettingsDestination | undefined
  >(() => {
    if (start !== undefined) {
      return start;
    }
    if (inboxSetup(snapshot) !== '') {
      return 'account';
    }
    return settingsColumns ? 'account' : undefined;
  });
  if (snapshot.kind === 'signed-out') {
    return null;
  }
  const copy = registrationCopy(t, snapshot);
  const actions = registrationActions(snapshot, failed);
  const button = settingsButton(busy);
  const name = snapshot.contactEmail ?? t('settings.productAccount');
  return (
    <AccountPage onInbox={onInbox}>
      <SettingsWorkspace
        account={name}
        destination={destination}
        onDestination={setDestination}
        accessory={
          <>
            {busy ? (
              <ActivityIndicator
                accessibilityLabel={t('registration.connecting')}
              />
            ) : null}
            {settingsColumns ? (
              button(t('registration.openInbox'), () => {
                onInbox();
                return Promise.resolve();
              })
            ) : (
              <Pressable
                accessibilityLabel={t('registration.openInbox')}
                accessibilityRole="button"
                accessibilityState={{ disabled: busy }}
                disabled={busy}
                onPress={onInbox}
                style={[
                  styles.back,
                  {
                    opacity: busy ? 0.4 : 1,
                    boxShadow: colors.smallGlassShadow,
                  },
                ]}>
                <Glass cornerRadius={22} />
                <SFSymbol
                  name="tray"
                  size={20}
                  color={colors.textPrimary}
                />
              </Pressable>
            )}
          </>
        }>
        {failed || actions.signIn.length > 0 ? (
          <SettingsGroup>
            <SettingsBlock>
              {failed ? (
                <Text
                  accessibilityRole="alert"
                  style={[styles.text, { color: colors.textPrimary }]}>
                  {t('registration.setupFailed')}
                </Text>
              ) : null}
              {actions.signIn.map(({ offer, provider }) => (
                <Fragment key={`${offer}-${provider}`}>
                  {button(
                    t(`registration.${offer}`, {
                      provider: providerName(t, provider),
                    }),
                    () => store.register(provider),
                  )}
                </Fragment>
              ))}
              {actions.retry ? button(t('common.retry'), store.restore) : null}
            </SettingsBlock>
          </SettingsGroup>
        ) : null}
        {destination === 'account' ? (
          <>
            <AccountCard
              name={name}
              detail={t('registration.account', {
                provider: providerName(t, snapshot.signInProvider),
              })}
            />
            <SettingsGroup footer={copy.description} />
          </>
        ) : null}
        {destination === 'language' ? <LanguageSelector /> : null}
        {actions.settings && destination !== undefined ? (
          <AccountSettings
            assistance={assistance}
            button={button}
            destination={destination}
            microsoft={microsoft}
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
      </SettingsWorkspace>
    </AccountPage>
  );
}

function RegistrationPage({
  assistance,
  microsoft,
  start,
  store,
  onInbox,
}: {
  readonly assistance: NativeAssistance;
  readonly microsoft: boolean;
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
  const copy = registrationCopy(t, snapshot);
  const actions = registrationActions(snapshot, failed);
  // A connected Inbox's account page is Settings.
  if (onInbox !== undefined && snapshot.kind !== 'signed-out') {
    return (
      <SettingsPage
        assistance={assistance}
        microsoft={microsoft}
        start={start}
        store={store}
        onInbox={onInbox}
      />
    );
  }
  const button = (label: string, action: () => Promise<void>) => (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ disabled: busy }}
      disabled={busy}
      onPress={() => {
        void action();
      }}
      style={[styles.button, { borderColor: colors.separator }]}>
      <Text style={[styles.text, { color: colors.textPrimary }]}>{label}</Text>
    </Pressable>
  );
  return (
    <ScrollView
      contentContainerStyle={styles.scroll}
      style={[styles.page, { backgroundColor: colors.surfaceContent }]}>
      <View style={styles.content}>
        <Text
          accessibilityRole="header"
          style={[styles.title, { color: colors.textPrimary }]}>
          {copy.title}
        </Text>
        <Text style={[styles.text, { color: colors.textSecondary }]}>
          {copy.description}
        </Text>
        {copy.account === undefined ? null : (
          <Text style={[styles.text, { color: colors.textSecondary }]}>
            {copy.account}
          </Text>
        )}
        {busy ? (
          <ActivityIndicator
            accessibilityLabel={t('registration.connecting')}
          />
        ) : null}
        {failed ? (
          <Text
            accessibilityRole="alert"
            style={[styles.text, { color: colors.textPrimary }]}>
            {t('registration.setupFailed')}
          </Text>
        ) : null}
        {actions.firstMailbox ? (
          <>
            {button(t('registration.authorizeGmail'), () =>
              store.addMailbox('gmail'),
            )}
            {button(t('registration.chooseMailbox'), () =>
              store.addMailbox('gmail', true),
            )}
            {microsoft
              ? button(t('registration.connectMicrosoft'), () =>
                  store.addMailbox('microsoft-graph'),
                )
              : null}
            <ImapSetup
              button={button}
              store={store}
            />
          </>
        ) : null}
        {actions.signIn.map(({ offer, provider }) => (
          <Fragment key={`${offer}-${provider}`}>
            {button(
              t(`registration.${offer}`, {
                provider: providerName(t, provider),
              }),
              () => store.register(provider),
            )}
          </Fragment>
        ))}
        {actions.retry ? button(t('common.retry'), store.restore) : null}
        {actions.settings ? (
          <AccountSettings
            assistance={assistance}
            button={button}
            microsoft={microsoft}
            store={store}
          />
        ) : null}
        {snapshot.kind === 'signed-out' ? null : (
          <AccountActions
            button={button}
            failure={removalFailure}
            pending={snapshot.removalPending}
            store={store}
          />
        )}
        <LanguageSelector />
      </View>
    </ScrollView>
  );
}
