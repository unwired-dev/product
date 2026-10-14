import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type { MailAssistanceEnablementStore } from '@private-email/mail-core/assistance-enablement';
import type {
  AccountRemoval,
  InboxChoice,
  EnrollmentFailure,
  LinkFailure,
  MailboxConnection,
  PrivateSync as PrivateSyncState,
  RecoveryFailure,
  RecoveryKeyFailure,
  Registration,
  RemovalFailure,
} from '@private-email/mail-core/registration';
import type { RemoteContentSettingsStore } from '@private-email/mail-core/remote-content';
import type { NativeTranslation } from '@private-email/mail-core/translation';
import type { ReactNode } from 'react';

import {
  approvesDevices,
  linkFailureCopy,
  inboxLanding,
  mailboxesOf,
  offersRecovery,
  otherSignInProvider,
  privateSyncCopy,
  providerName,
  recoveryKeyEntry,
  registrationActions,
  registrationCopy,
  signInMethodsCopy,
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
  ScrollView,
  Text,
  TextInput,
  View,
} from 'react-native';

import { AccountPage } from './account-page.tsx';
import { Button, Notice } from './design.tsx';
import { ImapSetup } from './imap-setup.tsx';
import { Label } from './label.tsx';
import { LanguageSelector } from './language-selector.tsx';
import { useLocalization } from './localization.ts';
import {
  MailAssistanceContext,
  MailAssistanceGate,
  MailAssistanceSettings,
  mailAssistance as deviceMailAssistance,
} from './mail-assistance.tsx';
import { AssistanceContext, nativeAssistance } from './message-summary.tsx';
import { TrustCard } from './onboarding.tsx';
import { FirstMailbox, SignedOutPage } from './registration-onboarding.tsx';
import { registrationStyles as styles } from './registration-styles.ts';
import { microsoftMail, registration } from './registration.ts';
import {
  MailboxRemoteContent,
  RemoteContentSettings,
  remoteContent as deviceRemoteContent,
  RemoteContentContext,
} from './remote-content.tsx';
import { usePalette } from './theme.ts';
import { TranslationContext, nativeTranslation } from './translation.tsx';
import { TrustedDevices } from './trusted-devices.tsx';

// The connected Inbox opens the account page and asks a mailbox's provider for permission again
// through this.
export const AccountContext = createContext<
  | Readonly<{
      // Every Mailbox Connection, including those waiting for authorization again.
      mailboxes: readonly MailboxConnection[];
      openAccount: () => void;
      authorizeMailbox: (connection: string) => Promise<void>;
      refreshInbox: (load: () => Promise<void>) => Promise<void>;
    }>
  | undefined
>(undefined);

// A registration action: quiet by default, accent for a step's primary action.
type ActionButton = (
  label: string,
  action: () => Promise<void>,
  fill?: 'accent' | 'destructive',
) => ReactNode;

// Each Mailbox Connection with its state, adding another, and removal after confirmation.
function Mailboxes({
  account,
  button,
  microsoft,
  store,
}: {
  readonly account: Readonly<{ mailboxes?: string }>;
  readonly button: ActionButton;
  readonly microsoft: boolean;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [confirming, setConfirming] = useState<MailboxConnection['id']>();
  // The IMAP connection whose password is being entered again, or a new one being added.
  const [imap, setImap] = useState<
    { kind: 'repair'; id: MailboxConnection['id'] } | { kind: 'new' }
  >();
  const mailboxes = mailboxesOf(account);
  if (mailboxes.length === 0) {
    return null;
  }
  return (
    <>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.textPrimary }]}>
        {t('mailboxes.title')}
      </Label>
      <Label style={[styles.text, { color: colors.textSecondary }]}>
        {t('mailboxes.description')}
      </Label>
      {mailboxes.map((mailbox) => {
        const provider = t(`mailProviders.${mailbox.provider}`);
        const imapMailbox = mailbox.provider === 'imap';
        const repairing = imap?.kind === 'repair' && imap.id === mailbox.id;
        return (
          <View
            key={mailbox.id}
            style={styles.device}>
            <Label style={[styles.text, { color: colors.textPrimary }]}>
              {mailbox.address}
            </Label>
            <Label style={[styles.text, { color: colors.textSecondary }]}>
              {t(
                imapMailbox && mailbox.state !== 'connected'
                  ? `mailboxes.states.imap-${mailbox.state}`
                  : `mailboxes.states.${mailbox.state}`,
                { provider },
              )}
            </Label>
            {/* Saved before SMTP: entering the password again sets up sending. */}
            {imapMailbox && mailbox.smtp === undefined ? (
              <Label style={[styles.text, { color: colors.textSecondary }]}>
                {t('mailboxes.receiveOnly')}
              </Label>
            ) : null}
            {mailbox.state === 'authorization' && !imapMailbox
              ? button(
                  t('mailboxes.allow', { address: mailbox.address, provider }),
                  () => store.authorizeMailbox(mailbox.id),
                )
              : null}
            {imapMailbox && !repairing
              ? button(
                  t('mailboxes.enterPassword', { address: mailbox.address }),
                  async () => {
                    setImap({ kind: 'repair', id: mailbox.id });
                  },
                )
              : null}
            {repairing ? (
              <ImapSetup
                button={button}
                onClose={() => {
                  setImap(undefined);
                }}
                repair={mailbox}
                store={store}
              />
            ) : null}
            {/* Remote Message Content never loads for IMAP mail yet. */}
            {imapMailbox ? null : <MailboxRemoteContent {...mailbox} />}
            {confirming === mailbox.id ? (
              <>
                <Label style={[styles.text, { color: colors.textPrimary }]}>
                  {t(
                    imapMailbox
                      ? 'mailboxes.confirm_imap'
                      : 'mailboxes.confirm',
                    {
                      address: mailbox.address,
                      provider,
                    },
                  )}
                </Label>
                {button(
                  t('mailboxes.remove', { address: mailbox.address }),
                  async () => {
                    setConfirming(undefined);
                    await store.removeMailbox(mailbox.id);
                  },
                )}
                {button(t('mailboxes.cancel'), async () => {
                  setConfirming(undefined);
                })}
              </>
            ) : (
              button(
                t('mailboxes.remove', { address: mailbox.address }),
                async () => {
                  setConfirming(mailbox.id);
                },
              )
            )}
          </View>
        );
      })}
      {button(t('mailboxes.add'), () => store.addMailbox('gmail', true))}
      {microsoft
        ? button(t('mailboxes.addMicrosoft'), () =>
            store.addMailbox('microsoft-graph'),
          )
        : null}
      {imap?.kind === 'new' ? (
        <ImapSetup
          button={button}
          onClose={() => {
            setImap(undefined);
          }}
          store={store}
        />
      ) : (
        button(t('mailboxes.addImap'), async () => {
          setImap({ kind: 'new' });
        })
      )}
      <RemoteContentSettings button={button} />
    </>
  );
}

// End-to-End Encrypted Product Sync; the Recovery Key stays visible until its setup is confirmed.
function PrivateSync({
  account,
  button,
  failure,
  store,
}: {
  readonly account: Parameters<typeof privateSyncCopy>[1];
  readonly button: ActionButton;
  readonly failure: RecoveryKeyFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [entry, setEntry] = useState('');
  const copy = privateSyncCopy(t, account);
  if (copy === undefined) {
    return null;
  }
  const { recoveryKey, enrollmentCode } = copy;
  const notes = (
    <>
      {copy.mailboxes === undefined ? null : (
        <Label style={[styles.text, { color: colors.textSecondary }]}>
          {copy.mailboxes}
        </Label>
      )}
      {copy.pending === undefined ? null : (
        <Label style={[styles.text, { color: colors.textPrimary }]}>
          {copy.pending}
        </Label>
      )}
    </>
  );
  if (recoveryKey !== undefined) {
    return (
      <TrustCard
        icon="key"
        title={copy.title}
        description={copy.description}>
        <Text
          selectable
          testID="recovery-key"
          style={[
            styles.recoveryKey,
            { color: colors.textPrimary, backgroundColor: colors.fillQuiet },
          ]}>
          {recoveryKey}
        </Text>
        <Label style={[styles.text, { color: colors.textSecondary }]}>
          {t('recoveryKeyConfirmation.prompt')}
        </Label>
        <TextInput
          accessibilityLabel={t('recoveryKeyConfirmation.label')}
          autoCapitalize="characters"
          autoComplete="off"
          autoCorrect={false}
          onChangeText={(text) => {
            setEntry(recoveryKeyEntry(text));
          }}
          placeholder={t('recoveryKeyConfirmation.label')}
          placeholderTextColor={colors.textSecondary}
          style={[
            styles.input,
            { borderColor: colors.separator, color: colors.textPrimary },
          ]}
          value={entry}
        />
        {failure === undefined ? null : (
          <Label
            accessibilityRole="alert"
            style={[styles.text, { color: colors.textPrimary }]}>
            {t(`recoveryKeyConfirmation.${failure}`)}
          </Label>
        )}
        {button(
          t('recoveryKeyConfirmation.confirm'),
          () => store.confirmRecoveryKey(entry),
          'accent',
        )}
        {notes}
      </TrustCard>
    );
  }
  if (enrollmentCode !== undefined) {
    return (
      <TrustCard
        icon="laptopcomputer.and.iphone"
        title={copy.title}
        description={copy.description}>
        <Text
          accessibilityLabel={enrollmentCode}
          selectable
          testID="enrollment-code"
          style={[
            styles.code,
            { color: colors.textPrimary, backgroundColor: colors.fillQuiet },
          ]}>
          {enrollmentCode.replaceAll('-', ' ')}
        </Text>
        {button(t('enrollment.check'), store.refreshPrivateSync, 'accent')}
        {notes}
      </TrustCard>
    );
  }
  return (
    <>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.textPrimary }]}>
        {copy.title}
      </Label>
      <Label style={[styles.text, { color: colors.textSecondary }]}>
        {copy.description}
      </Label>
      {notes}
    </>
  );
}

// Without an available trusted device, the Recovery Key unlocks this one; nothing offers a reset.
function RecoveryKeyUnlock({
  account,
  button,
  failure,
  store,
}: {
  readonly account: Readonly<{ privateSync?: PrivateSyncState }>;
  readonly button: ActionButton;
  readonly failure: RecoveryFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [entry, setEntry] = useState('');
  if (!offersRecovery(account.privateSync)) {
    return null;
  }
  return (
    <TrustCard
      icon="key"
      title={t('recovery.title')}
      description={t('recovery.description')}>
      <TextInput
        accessibilityLabel={t('recovery.label')}
        autoCapitalize="characters"
        autoComplete="off"
        autoCorrect={false}
        onChangeText={setEntry}
        placeholder={t('recovery.label')}
        placeholderTextColor={colors.textSecondary}
        style={[
          styles.input,
          { borderColor: colors.separator, color: colors.textPrimary },
        ]}
        value={entry}
      />
      {failure === undefined ? null : (
        <Label
          accessibilityRole="alert"
          style={[styles.text, { color: colors.textPrimary }]}>
          {t(`recovery.${failure}`)}
        </Label>
      )}
      {button(
        t('recovery.unlock'),
        () => store.recoverWithRecoveryKey(entry),
        'accent',
      )}
      <Notice
        icon="info.circle"
        message={t('recovery.lost')}
      />
    </TrustCard>
  );
}

// A trusted device approves another device only with the code that device shows.
function DeviceApproval({
  account,
  button,
  failure,
  store,
}: {
  readonly account: Readonly<{
    privateSync?: PrivateSyncState;
    enrollmentRequest?: string;
    enrollmentDevice?: string;
  }>;
  readonly button: ActionButton;
  readonly failure: EnrollmentFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [entry, setEntry] = useState('');
  const { enrollmentRequest: request } = account;
  if (!approvesDevices(account.privateSync)) {
    return null;
  }
  const alert =
    failure === undefined ? null : (
      <Label
        accessibilityRole="alert"
        style={[styles.text, { color: colors.textPrimary }]}>
        {t(`enrollment.${failure}`)}
      </Label>
    );
  if (request === undefined) {
    return (
      <>
        {alert}
        {button(t('enrollment.find'), store.refreshPrivateSync)}
      </>
    );
  }
  return (
    <TrustCard
      icon="laptopcomputer.and.iphone"
      title={t('enrollment.title')}
      description={t('enrollment.description', {
        device: account.enrollmentDevice ?? t('enrollment.device'),
      })}>
      <TextInput
        accessibilityLabel={t('enrollment.label')}
        autoCapitalize="characters"
        autoComplete="off"
        autoCorrect={false}
        onChangeText={setEntry}
        placeholder={t('enrollment.label')}
        placeholderTextColor={colors.textSecondary}
        style={[
          styles.input,
          { borderColor: colors.separator, color: colors.textPrimary },
        ]}
        value={entry}
      />
      {alert}
      {button(
        t('enrollment.approve'),
        () => store.approveEnrollment(request, entry),
        'accent',
      )}
      {button(
        t('enrollment.decline'),
        () => store.declineEnrollment(request),
        'destructive',
      )}
      {/* A request that expired or was handled elsewhere is replaced by the newest one. */}
      {button(t('enrollment.find'), store.refreshPrivateSync)}
    </TrustCard>
  );
}

// Account settings: Linked Sign-Ins never come from a mailbox grant or a matching email.
function SignInMethods({
  account,
  button,
  failure,
  store,
}: {
  readonly account: Parameters<typeof signInMethodsCopy>[1];
  readonly button: ActionButton;
  readonly failure: LinkFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const methods = signInMethodsCopy(t, account);
  const { link } = methods;
  return (
    <>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.textPrimary }]}>
        {t('signInMethods.title')}
      </Label>
      <Label style={[styles.text, { color: colors.textSecondary }]}>
        {methods.description}
      </Label>
      {failure === undefined ? null : (
        <Label
          accessibilityRole="alert"
          style={[styles.text, { color: colors.textPrimary }]}>
          {linkFailureCopy(
            t,
            failure,
            otherSignInProvider(account.signInProvider),
          )}
        </Label>
      )}
      {link === undefined
        ? null
        : button(
            t('signInMethods.link', { provider: providerName(t, link) }),
            () => store.link(link),
          )}
    </>
  );
}

// Leaving this device and deleting the Product Account everywhere are distinct, each confirmed
// here first; deletion then asks for a new sign-in.
function AccountActions({
  button,
  failure,
  pending,
  store,
}: {
  readonly button: ActionButton;
  readonly failure: RemovalFailure | undefined;
  readonly pending: AccountRemoval | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [confirming, setConfirming] = useState<AccountRemoval>();
  const selected = pending ?? confirming;
  const confirmation =
    selected === 'sign-out'
      ? {
          description: t('accountRemoval.signOutConfirm'),
          label: t('accountRemoval.signOut'),
          action: store.signOut,
        }
      : {
          description: t('accountRemoval.deleteConfirm'),
          label: t('accountRemoval.deletePermanently'),
          action: store.deleteProductAccount,
        };
  return (
    <>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.textPrimary }]}>
        {t('accountRemoval.title')}
      </Label>
      {failure === undefined ? null : (
        <Label
          accessibilityRole="alert"
          style={[styles.text, { color: colors.textPrimary }]}>
          {t(`accountRemoval.${failure}`)}
        </Label>
      )}
      {selected === undefined ? (
        <>
          {button(t('accountRemoval.signOut'), async () => {
            setConfirming('sign-out');
          })}
          {button(t('accountRemoval.delete'), async () => {
            setConfirming('deletion');
          })}
        </>
      ) : (
        <>
          <Label style={[styles.text, { color: colors.textPrimary }]}>
            {confirmation.description}
          </Label>
          {button(confirmation.label, confirmation.action)}
          {pending === undefined
            ? button(t('accountRemoval.cancel'), async () => {
                setConfirming(undefined);
              })
            : null}
        </>
      )}
    </>
  );
}

// A signed-in account's settings; until a trusted device or the Recovery Key admits this device,
// it offers only that.
function AccountSettings({
  assistance,
  button,
  microsoft,
  store,
}: {
  readonly assistance: NativeAssistance;
  readonly button: ActionButton;
  readonly microsoft: boolean;
  readonly store: Registration;
}) {
  const {
    snapshot,
    linkFailure,
    recoveryKeyFailure,
    recoveryFailure,
    enrollmentFailure,
    revocationFailure,
  } = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = useLocalization();
  if (snapshot.kind === 'signed-out') {
    return null;
  }
  const recovery = (
    <RecoveryKeyUnlock
      account={snapshot}
      button={button}
      failure={recoveryFailure}
      store={store}
    />
  );
  if (snapshot.kind === 'device-pending') {
    return (
      <>
        {privateSyncCopy(t, snapshot)?.enrollmentCode === undefined ? (
          button(t('enrollment.check'), store.refreshPrivateSync)
        ) : (
          <PrivateSync
            account={snapshot}
            button={button}
            failure={recoveryKeyFailure}
            store={store}
          />
        )}
        {recovery}
      </>
    );
  }
  return (
    <>
      <Mailboxes
        account={snapshot}
        button={button}
        microsoft={microsoft}
        store={store}
      />
      {snapshot.removalPending === undefined ? (
        <MailAssistanceSettings
          account={snapshot.productAccountId}
          assistance={assistance}
          button={button}
        />
      ) : null}
      <PrivateSync
        key={snapshot.recoveryKey ?? 'confirmed'}
        account={snapshot}
        button={button}
        failure={recoveryKeyFailure}
        store={store}
      />
      {recovery}
      <DeviceApproval
        // A code typed for one request never carries over to the next.
        key={snapshot.enrollmentRequest ?? 'none'}
        account={snapshot}
        button={button}
        failure={enrollmentFailure}
        store={store}
      />
      <TrustedDevices
        account={snapshot}
        button={button}
        failure={revocationFailure}
        store={store}
      />
      <SignInMethods
        account={snapshot}
        button={button}
        failure={linkFailure}
        store={store}
      />
    </>
  );
}

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
  const landing = inboxLanding(snapshot, choice);
  const { account: inboxAccount, setup } = landing;
  if (choice !== undefined && !landing.valid) {
    setChoice(undefined);
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
      openAccount: () => {
        if (inboxAccount !== undefined) {
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

function RegistrationPage({
  assistance,
  microsoft,
  store,
  onInbox,
}: {
  readonly assistance: NativeAssistance;
  readonly microsoft: boolean;
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
  if (snapshot.kind === 'signed-out') {
    return <SignedOutPage store={store} />;
  }
  const copy = registrationCopy(t, snapshot);
  const actions = registrationActions(snapshot, failed);
  const button: ActionButton = (label, action, fill) => (
    <Button
      disabled={busy}
      fill={fill ?? 'quiet'}
      label={label}
      onPress={() => {
        void action();
      }}
    />
  );
  // Microsoft's refusal usually means the organization has not approved Unwired Mail yet.
  const organizationApproval =
    snapshot.kind === 'mailbox-needed' &&
    snapshot.reason === 'microsoft-unavailable' &&
    snapshot.removalPending === undefined;
  const page = (
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
        {onInbox === undefined
          ? null
          : button(
              t('registration.openInbox'),
              () => {
                onInbox();
                return Promise.resolve();
              },
              'accent',
            )}
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
        <AccountActions
          button={button}
          failure={removalFailure}
          pending={snapshot.removalPending}
          store={store}
        />
        <LanguageSelector />
      </View>
    </ScrollView>
  );
  return onInbox === undefined ? (
    page
  ) : (
    <AccountPage onInbox={onInbox}>{page}</AccountPage>
  );
}
