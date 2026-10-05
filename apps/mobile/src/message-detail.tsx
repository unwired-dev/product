import { spacing } from '@private-email/mail-core/theme';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-screens/experimental';

import { useInbox, useInboxActions } from './mailbox.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  fill: { flex: 1 },
  content: {
    width: '100%',
    maxWidth: 760,
    alignSelf: 'center',
    padding: spacing.extraLarge,
  },
  subject: {
    fontSize: 28,
    lineHeight: 36,
    fontWeight: '600',
    letterSpacing: -0.5,
  },
  metadata: {
    gap: 5,
    marginTop: spacing.large,
    paddingBottom: spacing.large,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  sender: { fontSize: 16, fontWeight: '600' },
  secondary: { fontSize: 14, lineHeight: 21 },
  body: { fontSize: 17, lineHeight: 28, marginTop: spacing.large },
  empty: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.extraLarge,
    gap: spacing.small,
  },
  emptyTitle: { fontSize: 22, fontWeight: '500', textAlign: 'center' },
  emptyDescription: { fontSize: 16, textAlign: 'center' },
});

const dateFormat = new Intl.DateTimeFormat('en', {
  dateStyle: 'long',
  timeStyle: 'short',
  timeZone: 'UTC',
});

export function MessageDetail({ id }: { readonly id: string | undefined }) {
  const state = useInbox();
  const actions = useInboxActions();
  const colors = usePalette();
  const message =
    state.kind === 'ready'
      ? state.messages.find((item) => item.id === id)
      : undefined;

  if (state.kind === 'loading') {
    return (
      <ActivityIndicator
        accessibilityLabel="Loading message"
        style={styles.fill}
      />
    );
  }

  if (state.kind === 'locked' || state.kind === 'failed') {
    return (
      <View style={styles.empty}>
        <Text
          accessibilityRole="alert"
          style={[styles.emptyDescription, { color: colors.foreground }]}>
          {state.kind === 'locked'
            ? 'Private storage is locked. Unlock your device and try again.'
            : 'Private storage could not be opened or saved. Your stored data has been kept.'}
        </Text>
        <Pressable
          accessibilityRole="button"
          onPress={() => {
            void actions.load();
          }}>
          <Text style={[styles.secondary, { color: colors.accent }]}>
            Try again
          </Text>
        </Pressable>
      </View>
    );
  }

  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[styles.fill, { backgroundColor: colors.background }]}>
      {message === undefined ? (
        <View style={styles.empty}>
          <Text
            accessibilityRole="header"
            style={[styles.emptyTitle, { color: colors.foreground }]}>
            {id ? 'Message unavailable' : 'A little space for your mail'}
          </Text>
          <Text style={[styles.emptyDescription, { color: colors.secondary }]}>
            {id
              ? 'Choose another message from the Inbox.'
              : 'Select a message to start reading.'}
          </Text>
        </View>
      ) : (
        <ScrollView contentContainerStyle={styles.content}>
          {'setUnread' in actions ? (
            <Pressable
              accessibilityRole="button"
              onPress={() => {
                void actions.setUnread(message.id, !message.unread);
              }}>
              <Text style={[styles.secondary, { color: colors.accent }]}>
                {message.unread ? 'Mark as read' : 'Mark as unread'}
              </Text>
            </Pressable>
          ) : null}
          <Text
            accessibilityRole="header"
            selectable
            style={[styles.subject, { color: colors.foreground }]}>
            {message.subject}
          </Text>
          <View
            style={[styles.metadata, { borderBottomColor: colors.separator }]}>
            <Text
              selectable
              style={[styles.sender, { color: colors.foreground }]}>
              {message.sender}
            </Text>
            <Text
              selectable
              style={[styles.secondary, { color: colors.secondary }]}>
              {message.address}
            </Text>
            <Text style={[styles.secondary, { color: colors.secondary }]}>
              {dateFormat.format(new Date(message.receivedAt))} UTC
            </Text>
          </View>
          <Text
            selectable
            style={[styles.body, { color: colors.foreground }]}>
            {'body' in message ? message.body : message.preview}
          </Text>
        </ScrollView>
      )}
    </SafeAreaView>
  );
}
