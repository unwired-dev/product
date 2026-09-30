import type { Registration } from '@private-email/mail-core/registration';
import type { ReactNode } from 'react';

import { registrationCopy } from '@private-email/mail-core/registration';
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
  text: { fontSize: 17, lineHeight: 25 },
  button: {
    padding: 16,
    borderWidth: 1,
    borderRadius: 12,
    borderCurve: 'continuous',
  },
});

export function RegistrationGate({
  children,
  store = registration,
  preview = previewInbox,
}: {
  readonly children: ReactNode;
  readonly store?: Registration;
  readonly preview?: boolean;
}) {
  const { snapshot, busy, failed } = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
  );
  const colors = usePalette();
  const copy = registrationCopy(snapshot);
  useEffect(() => {
    if (!preview) {
      void store.restore();
    }
  }, [preview, store]);
  if (preview) {
    return children;
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
        {busy ? <ActivityIndicator accessibilityLabel="Connecting" /> : null}
        {failed ? (
          <Text
            accessibilityRole="alert"
            style={[styles.text, { color: colors.foreground }]}>
            Setup could not finish. Try again to resume your saved setup.
          </Text>
        ) : null}
        {snapshot.kind === 'signed-out'
          ? button('Sign in with Google', store.register)
          : null}
        {snapshot.kind === 'mailbox-needed'
          ? button('Authorize Gmail', () => store.authorizeGmail(false))
          : null}
        {snapshot.kind === 'signed-out'
          ? null
          : button('Choose another Google mailbox', () =>
              store.authorizeGmail(true),
            )}
        {snapshot.kind === 'mailbox-needed' &&
        (failed || snapshot.reason === 'interrupted')
          ? button('Sign in again with Google', store.register)
          : null}
        {failed ? button('Try again', store.restore) : null}
      </View>
    </View>
  );
}
