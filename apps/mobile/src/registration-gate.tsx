import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type { MailAssistanceEnablementStore } from '@private-email/mail-core/assistance-enablement';
import type { ErrorReporting } from '@private-email/mail-core/error-reporting';
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
  useContext,
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  ActivityIndicator,
  AppState,
  Keyboard,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ScreenStack, ScreenStackItem } from 'react-native-screens';

import type { SettingsDestination } from './settings.tsx';

import { AccountPage } from './account-page.tsx';
import { AccountActions, AccountSettings } from './account-settings.tsx';
import { Button, Glass, Notice, SFSymbol } from './design.tsx';
import {
  ErrorReportingContext,
  ErrorReportingDestination,
  ErrorReportingSettings,
} from './error-reporting.tsx';
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
  errorReporting as deviceErrorReporting,
  microsoftMail,
  registration,
  remoteContent as deviceRemoteContent,
} from './registration.ts';
import { RemoteContentContext } from './remote-content.tsx';
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

// The connected Inbox opens Settings and asks a mailbox's provider for permission again through
// this.
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

// A request to open Settings over the connected Inbox; each is a new value, so open Settings
// follows it.
type SettingsRequest = Readonly<{
  account: string;
  destination: SettingsDestination | undefined;
}>;

// Settings stays open only over the Inbox of the Product Account it opened for, so sign-out,
// locking, pending setup or another Product Account closes it.
const coveringSettings = (
  settings: SettingsRequest | undefined,
  screen: RegistrationScreen,
) =>
  screen.destination === 'inbox' &&
  settings?.account === screen.choices?.inbox.account
    ? settings
    : undefined;

function RegistrationGateContent({
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
  const reporting = useContext(ErrorReportingContext);
  const registrationState = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
  );
  const { snapshot, busy, locked } = registrationState;
  const colors = usePalette();
  const { t } = useLocalization();
  // The person's choice between the account page and a connected Inbox outlasts status updates.
  const [choice, setChoice] = useState<InboxChoice>();
  // Settings, which the connected Inbox opens over itself for one Product Account, and the
  // destination last asked for.
  const [settings, setSettings] = useState<SettingsRequest>();
  const screen = registrationScreen(t, registrationState, choice);
  const { choices } = screen;
  // A choice the shared rule no longer applies is forgotten, so an earlier snapshot cannot revive it.
  if (screen.choice !== choice) {
    setChoice(screen.choice);
  }
  // Settings closes with the Inbox it covers, so a later Inbox does not reopen it.
  const shownSettings = coveringSettings(settings, screen);
  if (shownSettings !== settings) {
    setSettings(shownSettings);
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
          // A field beneath Settings keeps its text but not the keyboard.
          Keyboard.dismiss();
          setSettings({ account: choices.inbox.account, destination });
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
        void reporting.refresh();
      }
    });
    return () => {
      subscription.remove();
    };
  }, [preview, store, reporting]);
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
          <SettingsCover
            onClose={() => {
              setSettings(undefined);
            }}
            settings={
              shownSettings === undefined ? undefined : (
                <SettingsPage
                  // Another Product Account starts Settings afresh.
                  key={shownSettings.account}
                  assistance={assistance}
                  microsoft={microsoft}
                  request={shownSettings}
                  screen={screen}
                  store={store}
                  onInbox={() => {
                    setSettings(undefined);
                  }}
                />
              )
            }>
            <MailAssistanceGate
              account={assistanceAccount}
              assistance={assistance}
              translation={translation}>
              <AccountContext value={actions}>{children}</AccountContext>
            </MailAssistanceGate>
          </SettingsCover>
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
  // Until launch reads saved registration, a configured app must not flash Welcome (#1070).
  if (screen.destination === 'restoring') {
    return (
      <View style={[styles.page, { backgroundColor: colors.surfaceContent }]} />
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

// Settings over the connected Inbox, which stays mounted beneath it with its Draft, mailbox and
// reader, and leaves the accessibility tree to Settings.
function SettingsCover({
  settings,
  onClose,
  children,
}: {
  readonly settings: ReactNode;
  readonly onClose: () => void;
  readonly children: ReactNode;
}) {
  const covered = settings !== undefined;
  const [mailShown, setMailShown] = useState(false);
  if (!settingsColumns) {
    return (
      <ScreenStack style={styles.page}>
        <ScreenStackItem
          screenId="mail"
          activityState={2}
          freezeOnBlur={false}
          headerConfig={{ hidden: true }}
          onAppear={() => {
            setMailShown(true);
          }}>
          <View
            accessibilityElementsHidden={covered}
            importantForAccessibility={covered ? 'no-hide-descendants' : 'auto'}
            style={styles.page}>
            {/* react-native-screens 4.26 gives a split view its columns only when it mounts inside the
                window, which this screen joins after its own first mount (#1111). */}
            {mailShown ? children : null}
          </View>
        </ScreenStackItem>
        {covered ? (
          <ScreenStackItem
            screenId="settings"
            testID="settings-screen"
            activityState={2}
            headerConfig={{ hidden: true }}
            gestureEnabled
            onDismissed={onClose}>
            {settings}
          </ScreenStackItem>
        ) : null}
      </ScreenStack>
    );
  }
  return (
    <>
      <View
        accessibilityElementsHidden={covered}
        importantForAccessibility={covered ? 'no-hide-descendants' : 'auto'}
        style={styles.page}>
        {children}
      </View>
      {covered ? (
        <View
          accessibilityViewIsModal
          style={StyleSheet.absoluteFill}>
          {settings}
        </View>
      ) : null}
    </>
  );
}

// Settings, one destination at a time: over the connected Inbox, or as its account page while
// account setup waits.
function reportingDetail(destination: SettingsDestination | undefined): {
  readonly destination: SettingsDestination | undefined;
  readonly detail: ReactNode;
} {
  if (!settingsColumns && destination === 'errorReporting') {
    return { destination: 'privacy', detail: <ErrorReportingSettings /> };
  }
  return { destination, detail: undefined };
}

function SettingsPage({
  assistance,
  microsoft,
  request,
  screen,
  store,
  onInbox,
}: {
  readonly assistance: NativeAssistance;
  readonly microsoft: boolean;
  readonly request?: SettingsRequest;
  readonly screen: RegistrationScreen;
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
    if (request?.destination !== undefined) {
      return request.destination;
    }
    if (screen.setupPending) {
      return 'account';
    }
    return settingsColumns ? 'account' : undefined;
  });
  // A later request names its destination; one without keeps the person's place.
  const [followed, setFollowed] = useState(request);
  if (followed !== request) {
    setFollowed(request);
    if (request?.destination !== undefined) {
      setDestination(request.destination);
    }
  }
  const { destination: selectedDestination, detail } =
    reportingDetail(destination);
  const { copy, actions, identity } = screen;
  if (snapshot.kind === 'signed-out' || identity === undefined) {
    return null;
  }
  const button = settingsButton(busy);
  const name = identity.name ?? t('settings.productAccount');
  return (
    <AccountPage onInbox={onInbox}>
      <SettingsWorkspace
        account={name}
        destination={selectedDestination}
        onDestination={setDestination}
        detail={detail}
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
              {actions.signIn.map(({ offer, provider, label }) => (
                <Fragment key={`${offer}-${provider}`}>
                  {button(label, () => store.register(provider))}
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
              detail={identity.provider}
            />
            <SettingsGroup footer={copy.description} />
          </>
        ) : null}
        {destination === 'language' ? <LanguageSelector /> : null}
        <ErrorReportingDestination
          destination={selectedDestination}
          onDestination={setDestination}
        />
        {actions.settings && selectedDestination !== undefined ? (
          <AccountSettings
            assistance={assistance}
            button={button}
            destination={selectedDestination}
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
      </SettingsWorkspace>
    </AccountPage>
  );
}

function RegistrationPage({
  assistance,
  microsoft,
  screen,
  store,
  onInbox,
}: {
  readonly assistance: NativeAssistance;
  readonly microsoft: boolean;
  readonly screen: RegistrationScreen;
  readonly store: Registration;
  // Returns to the connected Inbox, when it can open.
  readonly onInbox: (() => void) | undefined;
}) {
  const insets = useSafeAreaInsets();
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
      contentContainerStyle={[
        styles.scroll,
        !settingsColumns && {
          paddingLeft: insets.left + 24,
          paddingRight: insets.right + 24,
          paddingTop: insets.top + 62,
          paddingBottom: insets.bottom + 26,
        },
      ]}
      style={[styles.page, { backgroundColor: colors.surfaceContent }]}>
      <View style={[styles.content, !settingsColumns && { gap: 10 }]}>
        <Text
          accessibilityRole="header"
          style={[styles.title, { color: colors.textPrimary }]}>
          {copy.title}
        </Text>
        {organizationApproval ? (
          <Notice
            icon="building.2"
            iconColor={colors.statusWarning}
            message={copy.description}
          />
        ) : (
          <Text style={[styles.text, { color: colors.textSecondary }]}>
            {copy.description}
          </Text>
        )}
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

export function RegistrationGate({
  errorReporting = deviceErrorReporting,
  ...props
}: Parameters<typeof RegistrationGateContent>[0] & {
  readonly errorReporting?: ErrorReporting;
}) {
  return (
    <ErrorReportingContext.Provider value={errorReporting}>
      <RegistrationGateContent {...props} />
    </ErrorReportingContext.Provider>
  );
}
