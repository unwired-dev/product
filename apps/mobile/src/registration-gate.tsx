import type {
  EnrollmentFailure,
  LinkFailure,
  PrivateSync as PrivateSyncState,
  RecoveryFailure,
  RecoveryKeyFailure,
  Registration,
  RegistrationSnapshot,
} from '@private-email/mail-core/registration';
import type { ReactNode } from 'react';

import {
  enrollmentCopy,
  linkFailureCopy,
  lockedCopy,
  offersRecovery,
  otherSignInProvider,
  privateSyncCopy,
  providerNames,
  recoveryKeyConfirmationCopy,
  recoveryCopy,
  recoveryKeyEntry,
  registrationCopy,
  signInMethodsCopy,
} from '@private-email/mail-core/registration';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import { useEffect, useState, useSyncExternalStore } from 'react';
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
});

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
      <Text
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {copy.title}
      </Text>
      <Text style={[styles.text, { color: colors.secondary }]}>
        {copy.description}
      </Text>
      {recoveryKey === undefined ? null : (
        <>
          <Text
            selectable
            testID="recovery-key"
            style={[styles.recoveryKey, { color: colors.foreground }]}>
            {recoveryKey}
          </Text>
          <Text style={[styles.text, { color: colors.secondary }]}>
            {recoveryKeyConfirmationCopy.prompt}
          </Text>
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
            <Text
              accessibilityRole="alert"
              style={[styles.text, { color: colors.foreground }]}>
              {recoveryKeyConfirmationCopy[failure]}
            </Text>
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
        <Text style={[styles.text, { color: colors.secondary }]}>
          {copy.mailboxes}
        </Text>
      )}
      {copy.pending === undefined ? null : (
        <Text style={[styles.text, { color: colors.foreground }]}>
          {copy.pending}
        </Text>
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
      <Text
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {recoveryCopy.title}
      </Text>
      <Text style={[styles.text, { color: colors.secondary }]}>
        {recoveryCopy.description}
      </Text>
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
        <Text
          accessibilityRole="alert"
          style={[styles.text, { color: colors.foreground }]}>
          {recoveryCopy[failure]}
        </Text>
      )}
      {button(recoveryCopy.unlock, () => store.recoverWithRecoveryKey(entry))}
      <Text style={[styles.text, { color: colors.secondary }]}>
        {recoveryCopy.lost}
      </Text>
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
      <Text
        accessibilityRole="alert"
        style={[styles.text, { color: colors.foreground }]}>
        {enrollmentCopy[failure]}
      </Text>
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
      <Text
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {enrollmentCopy.title}
      </Text>
      <Text style={[styles.text, { color: colors.secondary }]}>
        {enrollmentCopy.description(account.enrollmentDevice ?? 'device')}
      </Text>
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
      <Text
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        Sign-in methods
      </Text>
      <Text style={[styles.text, { color: colors.secondary }]}>
        {methods.description}
      </Text>
      {failure === undefined ? null : (
        <Text
          accessibilityRole="alert"
          style={[styles.text, { color: colors.foreground }]}>
          {linkFailureCopy(
            failure,
            otherSignInProvider(account.signInProvider),
          )}
        </Text>
      )}
      {link === undefined
        ? null
        : button(`Link ${providerNames[link]} sign-in`, () => store.link(link))}
    </>
  );
}

// A retained account can be reopened with its own or its linked Sign-In Provider,
// which also finishes Product Sync setup that could not reach the backend.
function offersSignInAgain(
  snapshot: RegistrationSnapshot,
  failed: boolean,
): snapshot is Exclude<RegistrationSnapshot, { kind: 'signed-out' }> {
  if (snapshot.kind === 'signed-out') {
    return false;
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
  const { busy, locked } = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
  );
  const colors = usePalette();
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
  if (!locked) {
    return <RegistrationPage store={store} />;
  }
  return (
    <ScrollView
      contentContainerStyle={styles.scroll}
      style={[styles.page, { backgroundColor: colors.background }]}>
      <View style={styles.content}>
        <Text
          accessibilityRole="header"
          style={[styles.title, { color: colors.foreground }]}>
          {lockedCopy.title}
        </Text>
        <Text style={[styles.text, { color: colors.secondary }]}>
          {lockedCopy.description}
        </Text>
        {busy ? <ActivityIndicator accessibilityLabel="Connecting" /> : null}
      </View>
    </ScrollView>
  );
}

function RegistrationPage({ store }: { readonly store: Registration }) {
  const {
    snapshot,
    busy,
    failed,
    linkFailure,
    recoveryKeyFailure,
    recoveryFailure,
    enrollmentFailure,
  } = useSyncExternalStore(store.subscribe, store.getSnapshot);
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
        <Text
          accessibilityRole="header"
          style={[styles.title, { color: colors.foreground }]}>
          {copy.title}
        </Text>
        <Text style={[styles.text, { color: colors.secondary }]}>
          {copy.description}
        </Text>
        {copy.account === undefined ? null : (
          <Text style={[styles.text, { color: colors.secondary }]}>
            {copy.account}
          </Text>
        )}
        {busy ? <ActivityIndicator accessibilityLabel="Connecting" /> : null}
        {failed ? (
          <Text
            accessibilityRole="alert"
            style={[styles.text, { color: colors.foreground }]}>
            Setup could not finish. Try again to resume your saved setup.
          </Text>
        ) : null}
        {snapshot.kind === 'signed-out' ? (
          <>
            {button('Sign in with Apple', () => store.register('apple'))}
            {button('Sign in with Google', () => store.register('google'))}
          </>
        ) : null}
        {snapshot.kind === 'mailbox-needed'
          ? button('Authorize Gmail', () => store.authorizeGmail(false))
          : null}
        {snapshot.kind === 'signed-out'
          ? null
          : button('Choose another Google mailbox', () =>
              store.authorizeGmail(true),
            )}
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
        {snapshot.kind === 'signed-out' ? null : (
          <PrivateSync
            account={snapshot}
            button={button}
            failure={recoveryKeyFailure}
            store={store}
          />
        )}
        {snapshot.kind === 'signed-out' ? null : (
          <RecoveryKeyUnlock
            account={snapshot}
            button={button}
            failure={recoveryFailure}
            store={store}
          />
        )}
        {snapshot.kind === 'signed-out' ? null : (
          <DeviceApproval
            // A code typed for one request never carries over to the next.
            key={snapshot.enrollmentRequest ?? 'none'}
            account={snapshot}
            button={button}
            failure={enrollmentFailure}
            store={store}
          />
        )}
        {snapshot.kind === 'signed-out' ? null : (
          <SignInMethods
            account={snapshot}
            button={button}
            failure={linkFailure}
            store={store}
          />
        )}
      </View>
    </ScrollView>
  );
}
