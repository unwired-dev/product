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
  Pressable,
  ScrollView,
  Text,
  TextInput,
  View,
} from 'react-native';

import { LanguageSelector } from './language-selector.tsx';
import { useLocalization } from './localization.ts';
import { RegistrationLabel as Label } from './registration-label.tsx';
import { registrationStyles as styles } from './registration-styles.ts';
import { registration } from './registration.ts';
import { usePalette } from './theme.ts';
import { TrustedDevices } from './trusted-devices.tsx';

// The connected Inbox opens the account page and asks for Gmail permission again through this.
export const AccountContext = createContext<
  | Readonly<{
      // Every Mailbox Connection, including those waiting for Gmail authorization again.
      mailboxes: readonly MailboxConnection[];
      openAccount: () => void;
      authorizeGmail: (connection: string) => Promise<void>;
      refreshInbox: (load: () => Promise<void>) => Promise<void>;
    }>
  | undefined
>(undefined);

// Each Mailbox Connection with its state, adding another, and removal after confirmation.
function Mailboxes({
  account,
  button,
  store,
}: {
  readonly account: Readonly<{ mailboxes?: string }>;
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [confirming, setConfirming] = useState<MailboxConnection['id']>();
  const mailboxes = mailboxesOf(account);
  if (mailboxes.length === 0) {
    return null;
  }
  return (
    <>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {t('mailboxes.title')}
      </Label>
      <Label style={[styles.text, { color: colors.secondary }]}>
        {t('mailboxes.description')}
      </Label>
      {mailboxes.map((mailbox) => (
        <View
          key={mailbox.id}
          style={styles.device}>
          <Label style={[styles.text, { color: colors.foreground }]}>
            {mailbox.address}
          </Label>
          <Label style={[styles.text, { color: colors.secondary }]}>
            {t(`mailboxes.states.${mailbox.state}`)}
          </Label>
          {mailbox.state === 'authorization'
            ? button(t('mailboxes.allow', { address: mailbox.address }), () =>
                store.authorizeGmail(mailbox.id),
              )
            : null}
          {confirming === mailbox.id ? (
            <>
              <Label style={[styles.text, { color: colors.foreground }]}>
                {t('mailboxes.confirm', { address: mailbox.address })}
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
      ))}
      {button(t('mailboxes.add'), () => store.addMailbox(true))}
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
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
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
  const { recoveryKey } = copy;
  return (
    <>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {copy.title}
      </Label>
      <Label style={[styles.text, { color: colors.secondary }]}>
        {copy.description}
      </Label>
      {recoveryKey === undefined ? null : (
        <>
          <Text
            selectable
            testID="recovery-key"
            style={[styles.recoveryKey, { color: colors.foreground }]}>
            {recoveryKey}
          </Text>
          <Label style={[styles.text, { color: colors.secondary }]}>
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
            placeholderTextColor={colors.secondary}
            style={[
              styles.input,
              { borderColor: colors.separator, color: colors.foreground },
            ]}
            value={entry}
          />
          {failure === undefined ? null : (
            <Label
              accessibilityRole="alert"
              style={[styles.text, { color: colors.foreground }]}>
              {t(`recoveryKeyConfirmation.${failure}`)}
            </Label>
          )}
          {button(t('recoveryKeyConfirmation.confirm'), () =>
            store.confirmRecoveryKey(entry),
          )}
        </>
      )}
      {copy.enrollmentCode === undefined ? null : (
        <>
          <Text
            selectable
            testID="enrollment-code"
            style={[styles.recoveryKey, { color: colors.foreground }]}>
            {copy.enrollmentCode}
          </Text>
          {button(t('enrollment.check'), store.refreshPrivateSync)}
        </>
      )}
      {copy.mailboxes === undefined ? null : (
        <Label style={[styles.text, { color: colors.secondary }]}>
          {copy.mailboxes}
        </Label>
      )}
      {copy.pending === undefined ? null : (
        <Label style={[styles.text, { color: colors.foreground }]}>
          {copy.pending}
        </Label>
      )}
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
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
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
    <>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {t('recovery.title')}
      </Label>
      <Label style={[styles.text, { color: colors.secondary }]}>
        {t('recovery.description')}
      </Label>
      <TextInput
        accessibilityLabel={t('recovery.label')}
        autoCapitalize="characters"
        autoComplete="off"
        autoCorrect={false}
        onChangeText={setEntry}
        placeholder={t('recovery.label')}
        placeholderTextColor={colors.secondary}
        style={[
          styles.input,
          { borderColor: colors.separator, color: colors.foreground },
        ]}
        value={entry}
      />
      {failure === undefined ? null : (
        <Label
          accessibilityRole="alert"
          style={[styles.text, { color: colors.foreground }]}>
          {t(`recovery.${failure}`)}
        </Label>
      )}
      {button(t('recovery.unlock'), () => store.recoverWithRecoveryKey(entry))}
      <Label style={[styles.text, { color: colors.secondary }]}>
        {t('recovery.lost')}
      </Label>
    </>
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
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
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
        style={[styles.text, { color: colors.foreground }]}>
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
    <>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {t('enrollment.title')}
      </Label>
      <Label style={[styles.text, { color: colors.secondary }]}>
        {t('enrollment.description', {
          device: account.enrollmentDevice ?? t('enrollment.device'),
        })}
      </Label>
      <TextInput
        accessibilityLabel={t('enrollment.label')}
        autoCapitalize="characters"
        autoComplete="off"
        autoCorrect={false}
        onChangeText={setEntry}
        placeholder={t('enrollment.label')}
        placeholderTextColor={colors.secondary}
        style={[
          styles.input,
          { borderColor: colors.separator, color: colors.foreground },
        ]}
        value={entry}
      />
      {alert}
      {button(t('enrollment.approve'), () =>
        store.approveEnrollment(request, entry),
      )}
      {button(t('enrollment.decline'), () => store.declineEnrollment(request))}
      {/* A request that expired or was handled elsewhere is replaced by the newest one. */}
      {button(t('enrollment.find'), store.refreshPrivateSync)}
    </>
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
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
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
        style={[styles.heading, { color: colors.foreground }]}>
        {t('signInMethods.title')}
      </Label>
      <Label style={[styles.text, { color: colors.secondary }]}>
        {methods.description}
      </Label>
      {failure === undefined ? null : (
        <Label
          accessibilityRole="alert"
          style={[styles.text, { color: colors.foreground }]}>
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
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
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
        style={[styles.heading, { color: colors.foreground }]}>
        {t('accountRemoval.title')}
      </Label>
      {failure === undefined ? null : (
        <Label
          accessibilityRole="alert"
          style={[styles.text, { color: colors.foreground }]}>
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
          <Label style={[styles.text, { color: colors.foreground }]}>
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
  button,
  store,
}: {
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
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
        store={store}
      />
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
  preview = previewInbox,
}: {
  readonly children: ReactNode;
  readonly store?: Registration;
  readonly preview?: boolean;
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
      authorizeGmail: store.authorizeGmail,
      refreshInbox: store.refreshInbox,
    }),
    [store, snapshot, inboxAccount, setup],
  );
  useEffect(() => {
    if (preview) {
      return;
    }
    void store.restoreOnce();
    // Like the Inbox, restore on every activation, including after protected storage unlocks.
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') {
        void store.resume();
      }
    });
    return () => {
      subscription.remove();
    };
  }, [preview, store]);
  if (preview) {
    return children;
  }
  const inbox = landing.destination === 'inbox';
  if (!locked && inbox) {
    return <AccountContext value={actions}>{children}</AccountContext>;
  }
  if (!locked) {
    return (
      <RegistrationPage
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
    );
  }
  return (
    <ScrollView
      contentContainerStyle={styles.scroll}
      style={[styles.page, { backgroundColor: colors.background }]}>
      <View style={styles.content}>
        <Label
          accessibilityRole="header"
          style={[styles.title, { color: colors.foreground }]}>
          {t('locked.title')}
        </Label>
        <Label style={[styles.text, { color: colors.secondary }]}>
          {t('locked.description')}
        </Label>
        {busy ? (
          <ActivityIndicator
            accessibilityLabel={t('registration.connecting')}
          />
        ) : null}
      </View>
    </ScrollView>
  );
}

function RegistrationPage({
  store,
  onInbox,
}: {
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
  const button = (label: string, action: () => Promise<void>) => (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ disabled: busy }}
      disabled={busy}
      onPress={() => {
        void action();
      }}
      style={[styles.button, { borderColor: colors.separator }]}>
      <Text style={[styles.text, { color: colors.foreground }]}>{label}</Text>
    </Pressable>
  );
  return (
    <ScrollView
      contentContainerStyle={styles.scroll}
      style={[styles.page, { backgroundColor: colors.background }]}>
      <View style={styles.content}>
        <Label
          accessibilityRole="header"
          style={[styles.title, { color: colors.foreground }]}>
          {copy.title}
        </Label>
        <Label style={[styles.text, { color: colors.secondary }]}>
          {copy.description}
        </Label>
        {copy.account === undefined ? null : (
          <Label style={[styles.text, { color: colors.secondary }]}>
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
          : button(t('registration.openInbox'), () => {
              onInbox();
              return Promise.resolve();
            })}
        {failed ? (
          <Label
            accessibilityRole="alert"
            style={[styles.text, { color: colors.foreground }]}>
            {t('registration.setupFailed')}
          </Label>
        ) : null}
        {actions.firstMailbox ? (
          <>
            {button(t('registration.authorizeGmail'), () =>
              store.addMailbox(false),
            )}
            {button(t('registration.chooseMailbox'), () =>
              store.addMailbox(true),
            )}
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
            button={button}
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
