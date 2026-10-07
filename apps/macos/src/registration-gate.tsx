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
  RegistrationSnapshot,
  RemovalFailure,
  TrustedDevice,
} from '@private-email/mail-core/registration';
import type { ReactNode } from 'react';
import type { StyleProp, TextStyle } from 'react-native';

import {
  accountRemovalCopy,
  enrollmentCopy,
  linkFailureCopy,
  lockedCopy,
  inboxLanding,
  mailboxCopy,
  mailboxesOf,
  offersRecovery,
  otherSignInProvider,
  privateSyncCopy,
  providerNames,
  recoveryKeyConfirmationCopy,
  recoveryCopy,
  recoveryKeyEntry,
  registrationCopy,
  revocationCopy,
  revocationNotice,
  signInMethodsCopy,
  trustedDevicesOf,
} from '@private-email/mail-core/registration';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import {
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
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import { registration } from './registration.ts';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  page: { flex: 1 },
  scroll: {
    flexGrow: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 32,
  },
  content: { maxWidth: 420, width: '100%', gap: 20 },
  title: { fontSize: 28, fontWeight: '600' },
  heading: { fontSize: 20, fontWeight: '600' },
  text: { fontSize: 17, lineHeight: 25 },
  button: {
    padding: 16,
    borderWidth: 1,
    borderRadius: 12,
    borderCurve: 'continuous',
  },
  recoveryKey: {
    fontSize: 19,
    lineHeight: 30,
    fontFamily: 'Menlo',
    fontVariant: ['tabular-nums'],
  },
  input: {
    fontSize: 17,
    padding: 12,
    borderWidth: 1,
    borderRadius: 10,
    borderCurve: 'continuous',
  },
  device: { gap: 8 },
});

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
        {mailboxCopy.title}
      </Label>
      <Label style={[styles.text, { color: colors.secondary }]}>
        {mailboxCopy.description}
      </Label>
      {mailboxes.map((mailbox) => (
        <View
          key={mailbox.id}
          style={styles.device}>
          <Label style={[styles.text, { color: colors.foreground }]}>
            {mailbox.address}
          </Label>
          <Label style={[styles.text, { color: colors.secondary }]}>
            {mailboxCopy.states[mailbox.state]}
          </Label>
          {mailbox.state === 'authorization'
            ? button(mailboxCopy.allow(mailbox.address), () =>
                store.authorizeGmail(mailbox.id),
              )
            : null}
          {confirming === mailbox.id ? (
            <>
              <Label style={[styles.text, { color: colors.foreground }]}>
                {mailboxCopy.confirm(mailbox.address)}
              </Label>
              {button(mailboxCopy.remove(mailbox.address), async () => {
                setConfirming(undefined);
                await store.removeMailbox(mailbox.id);
              })}
              {button(mailboxCopy.cancel, async () => {
                setConfirming(undefined);
              })}
            </>
          ) : (
            button(mailboxCopy.remove(mailbox.address), async () => {
              setConfirming(mailbox.id);
            })
          )}
        </View>
      ))}
      {button(mailboxCopy.add, () => store.addMailbox(true))}
    </>
  );
}

// React Native macOS exposes plain Text to accessibility only through an accessible parent.
function Label({
  children,
  accessibilityRole = 'text',
  style,
}: {
  readonly children: string;
  readonly accessibilityRole?: 'alert' | 'header' | 'text';
  readonly style: StyleProp<TextStyle>;
}) {
  return (
    <View
      accessible
      accessibilityRole={accessibilityRole}
      accessibilityLabel={children}>
      <Text style={style}>{children}</Text>
    </View>
  );
}

// End-to-End Encrypted Product Sync; the Recovery Key stays visible until its setup is confirmed.
function PrivateSync({
  account,
  button,
  failure,
  store,
}: {
  readonly account: Parameters<typeof privateSyncCopy>[0];
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
  readonly failure: RecoveryKeyFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const [entry, setEntry] = useState('');
  const copy = privateSyncCopy(account);
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
            {recoveryKeyConfirmationCopy.prompt}
          </Label>
          <TextInput
            accessibilityLabel={recoveryKeyConfirmationCopy.label}
            autoCapitalize="characters"
            autoComplete="off"
            autoCorrect={false}
            onChangeText={(text) => {
              setEntry(recoveryKeyEntry(text));
            }}
            placeholder={recoveryKeyConfirmationCopy.label}
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
              {recoveryKeyConfirmationCopy[failure]}
            </Label>
          )}
          {button(recoveryKeyConfirmationCopy.confirm, () =>
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
          {button(enrollmentCopy.check, store.refreshPrivateSync)}
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
  const [entry, setEntry] = useState('');
  if (!offersRecovery(account.privateSync)) {
    return null;
  }
  return (
    <>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {recoveryCopy.title}
      </Label>
      <Label style={[styles.text, { color: colors.secondary }]}>
        {recoveryCopy.description}
      </Label>
      <TextInput
        accessibilityLabel={recoveryCopy.label}
        autoCapitalize="characters"
        autoComplete="off"
        autoCorrect={false}
        onChangeText={setEntry}
        placeholder={recoveryCopy.label}
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
          {recoveryCopy[failure]}
        </Label>
      )}
      {button(recoveryCopy.unlock, () => store.recoverWithRecoveryKey(entry))}
      <Label style={[styles.text, { color: colors.secondary }]}>
        {recoveryCopy.lost}
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
    privateSync?: string;
    enrollmentRequest?: string;
    enrollmentDevice?: string;
  }>;
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
  readonly failure: EnrollmentFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const [entry, setEntry] = useState('');
  const { enrollmentRequest: request } = account;
  if (
    account.privateSync !== 'ready' &&
    account.privateSync !== 'recovery-key'
  ) {
    return null;
  }
  const alert =
    failure === undefined ? null : (
      <Label
        accessibilityRole="alert"
        style={[styles.text, { color: colors.foreground }]}>
        {enrollmentCopy[failure]}
      </Label>
    );
  if (request === undefined) {
    return (
      <>
        {alert}
        {button(enrollmentCopy.find, store.refreshPrivateSync)}
      </>
    );
  }
  return (
    <>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {enrollmentCopy.title}
      </Label>
      <Label style={[styles.text, { color: colors.secondary }]}>
        {enrollmentCopy.description(account.enrollmentDevice ?? 'device')}
      </Label>
      <TextInput
        accessibilityLabel={enrollmentCopy.label}
        autoCapitalize="characters"
        autoComplete="off"
        autoCorrect={false}
        onChangeText={setEntry}
        placeholder={enrollmentCopy.label}
        placeholderTextColor={colors.secondary}
        style={[
          styles.input,
          { borderColor: colors.separator, color: colors.foreground },
        ]}
        value={entry}
      />
      {alert}
      {button(enrollmentCopy.approve, () =>
        store.approveEnrollment(request, entry),
      )}
      {button(enrollmentCopy.decline, () => store.declineEnrollment(request))}
      {/* A request that expired or was handled elsewhere is replaced by the newest one. */}
      {button(enrollmentCopy.find, store.refreshPrivateSync)}
    </>
  );
}

// Removing another Trusted Device is confirmed here; the native side then asks for a new sign-in.
function TrustedDevices({
  account,
  button,
  failed,
  store,
}: {
  readonly account: Readonly<{
    privateSync?: PrivateSyncState;
    trustedDevices?: string;
    revocationNotice?: 'removed' | 'unconfirmed';
  }>;
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
  readonly failed: boolean;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const [confirming, setConfirming] = useState<TrustedDevice['id']>();
  if (
    account.privateSync !== 'ready' &&
    account.privateSync !== 'recovery-key'
  ) {
    return null;
  }
  const devices =
    account.privateSync === 'ready' ? trustedDevicesOf(account) : [];
  const notice = revocationNotice(account, failed);
  if (devices.length === 0 && notice === undefined) {
    return null;
  }
  return (
    <>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {revocationCopy.title}
      </Label>
      {notice === undefined ? null : (
        <Label
          accessibilityRole="alert"
          style={[styles.text, { color: colors.foreground }]}>
          {notice}
        </Label>
      )}
      {devices.length === 0 ? null : (
        <Label style={[styles.text, { color: colors.secondary }]}>
          {revocationCopy.description}
        </Label>
      )}
      {devices.map((device) => (
        <View
          key={device.id}
          style={styles.device}>
          <Label style={[styles.text, { color: colors.foreground }]}>
            {device.name}
          </Label>
          <Label style={[styles.text, { color: colors.secondary }]}>
            {revocationCopy.added(device.registeredAt)}
          </Label>
          {confirming === device.id ? (
            <>
              <Label style={[styles.text, { color: colors.foreground }]}>
                {revocationCopy.confirm(device.name)}
              </Label>
              {button(revocationCopy.remove(device.name), () =>
                store.revokeTrustedDevice(device.id),
              )}
              {button(revocationCopy.cancel, async () => {
                setConfirming(undefined);
              })}
            </>
          ) : (
            button(revocationCopy.remove(device.name), async () => {
              setConfirming(device.id);
            })
          )}
        </View>
      ))}
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
  readonly account: Parameters<typeof signInMethodsCopy>[0];
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
  readonly failure: LinkFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const methods = signInMethodsCopy(account);
  const { link } = methods;
  return (
    <>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        Sign-in methods
      </Label>
      <Label style={[styles.text, { color: colors.secondary }]}>
        {methods.description}
      </Label>
      {failure === undefined ? null : (
        <Label
          accessibilityRole="alert"
          style={[styles.text, { color: colors.foreground }]}>
          {linkFailureCopy(
            failure,
            otherSignInProvider(account.signInProvider),
          )}
        </Label>
      )}
      {link === undefined
        ? null
        : button(`Link ${providerNames[link]} sign-in`, () => store.link(link))}
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
  const [confirming, setConfirming] = useState<AccountRemoval>();
  const selected = pending ?? confirming;
  const confirmation =
    selected === 'sign-out'
      ? {
          description: accountRemovalCopy.signOutConfirm,
          label: accountRemovalCopy.signOut,
          action: store.signOut,
        }
      : {
          description: accountRemovalCopy.deleteConfirm,
          label: accountRemovalCopy.deletePermanently,
          action: store.deleteProductAccount,
        };
  return (
    <>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {accountRemovalCopy.title}
      </Label>
      {failure === undefined ? null : (
        <Label
          accessibilityRole="alert"
          style={[styles.text, { color: colors.foreground }]}>
          {accountRemovalCopy[failure]}
        </Label>
      )}
      {selected === undefined ? (
        <>
          {button(accountRemovalCopy.signOut, async () => {
            setConfirming('sign-out');
          })}
          {button(accountRemovalCopy.delete, async () => {
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
            ? button(accountRemovalCopy.cancel, async () => {
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
    revocationFailed,
  } = useSyncExternalStore(store.subscribe, store.getSnapshot);
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
        {privateSyncCopy(snapshot)?.enrollmentCode === undefined ? (
          button(enrollmentCopy.check, store.refreshPrivateSync)
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
        failed={revocationFailed === true}
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

// A retained account can be reopened with its own or its linked Sign-In Provider,
// which also finishes Product Sync setup that could not reach the backend.
function offersSignInAgain(
  snapshot: RegistrationSnapshot,
  failed: boolean,
): snapshot is Exclude<RegistrationSnapshot, { kind: 'signed-out' }> {
  if (snapshot.kind === 'signed-out' || snapshot.removalPending !== undefined) {
    return false;
  }
  // A Pending Device is admitted by approval or the Recovery Key, not by another sign-in.
  if (snapshot.kind === 'device-pending') {
    return failed;
  }
  return (
    snapshot.privateSync === 'setup-pending' ||
    snapshot.privateSyncPending !== undefined ||
    (snapshot.kind === 'mailbox-needed' &&
      (failed ||
        snapshot.reason === 'interrupted' ||
        snapshot.reason === 'unavailable'))
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
          {lockedCopy.title}
        </Label>
        <Label style={[styles.text, { color: colors.secondary }]}>
          {lockedCopy.description}
        </Label>
        {busy ? <ActivityIndicator accessibilityLabel="Connecting" /> : null}
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
  const copy = registrationCopy(snapshot);
  const recovering = offersSignInAgain(snapshot, failed);
  // Offered even when this device has not seen the link; Convex decides.
  const alternate =
    snapshot.kind === 'signed-out'
      ? undefined
      : otherSignInProvider(snapshot.signInProvider);
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
        {busy ? <ActivityIndicator accessibilityLabel="Connecting" /> : null}
        {onInbox === undefined
          ? null
          : button('Open Inbox', () => {
              onInbox();
              return Promise.resolve();
            })}
        {failed ? (
          <Label
            accessibilityRole="alert"
            style={[styles.text, { color: colors.foreground }]}>
            Setup could not finish. Try again to resume your saved setup.
          </Label>
        ) : null}
        {snapshot.kind === 'signed-out' ? (
          <>
            {button('Sign in with Apple', () => store.register('apple'))}
            {button('Sign in with Google', () => store.register('google'))}
          </>
        ) : null}
        {/* The first mailbox suggests the Google sign-in, or any Google account can be chosen. */}
        {snapshot.kind === 'mailbox-needed' &&
        snapshot.removalPending === undefined &&
        mailboxesOf(snapshot).length === 0 ? (
          <>
            {button('Authorize Gmail', () => store.addMailbox(false))}
            {button('Choose another Google mailbox', () =>
              store.addMailbox(true),
            )}
          </>
        ) : null}
        {recovering
          ? button(
              `Sign in again with ${providerNames[snapshot.signInProvider]}`,
              () => store.register(snapshot.signInProvider),
            )
          : null}
        {recovering && alternate !== undefined
          ? button(`Sign in with ${providerNames[alternate]} instead`, () =>
              store.register(alternate),
            )
          : null}
        {failed ? button('Try again', store.restore) : null}
        {snapshot.kind === 'signed-out' ||
        snapshot.removalPending !== undefined ? null : (
          <AccountSettings
            button={button}
            store={store}
          />
        )}
        {snapshot.kind === 'signed-out' ? null : (
          <AccountActions
            button={button}
            failure={removalFailure}
            pending={snapshot.removalPending}
            store={store}
          />
        )}
      </View>
    </ScrollView>
  );
}
