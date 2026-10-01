import type {
  LinkFailure,
  Registration,
} from '@private-email/mail-core/registration';
import type { ReactNode } from 'react';

import {
  linkFailureCopy,
  otherSignInProvider,
  providerNames,
  registrationCopy,
  signInMethodsCopy,
} from '@private-email/mail-core/registration';
import { previewInbox } from '@private-email/mail-core/registration-mode';
import { useEffect, useSyncExternalStore } from 'react';
import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { registration } from './registration.ts';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  page: {
    flex: 1,
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
});

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

export function RegistrationGate({
  children,
  store = registration,
  preview = previewInbox,
}: {
  readonly children: ReactNode;
  readonly store?: Registration;
  readonly preview?: boolean;
}) {
  const { snapshot, busy, failed, linkFailure } = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
  );
  const colors = usePalette();
  const copy = registrationCopy(snapshot);
  useEffect(() => {
    if (!preview) {
      void store.restoreOnce();
    }
  }, [preview, store]);
  if (preview) {
    return children;
  }
  // A retained account can be reopened with its own or its linked Sign-In Provider.
  const recovering =
    snapshot.kind === 'mailbox-needed' &&
    (failed ||
      snapshot.reason === 'interrupted' ||
      snapshot.reason === 'unavailable');
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
    <View style={[styles.page, { backgroundColor: colors.background }]}>
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
          <SignInMethods
            account={snapshot}
            button={button}
            failure={linkFailure}
            store={store}
          />
        )}
      </View>
    </View>
  );
}
