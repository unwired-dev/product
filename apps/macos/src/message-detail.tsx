import { spacing } from '@private-email/mail-core/theme';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { useLocalization, useMessageDateFormat } from './localization.ts';
import { useInbox, useInboxActions } from './mailbox.ts';
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

export function MessageDetail({ id }: { readonly id: string | undefined }) {
  const state = useInbox();
  const actions = useInboxActions();
  const colors = usePalette();
  const { t } = useLocalization();
  const dateFormat = useMessageDateFormat(true);
  const message =
    state.kind === 'ready'
      ? state.messages.find((item) => item.id === id)
      : undefined;

  if (state.kind === 'loading') {
    return (
      <ActivityIndicator
        accessibilityLabel={t('message.loading')}
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
          {state.kind === 'locked' ? t('storage.locked') : t('storage.failed')}
        </Text>
        <Pressable
          accessibilityRole="button"
          onPress={() => {
            void actions.load();
          }}>
          <Text style={[styles.secondary, { color: colors.accent }]}>
            {t('storage.retry')}
          </Text>
        </Pressable>
      </View>
    );
  }

  return (
    <View style={[styles.fill, { backgroundColor: colors.background }]}>
      {message === undefined ? (
        <View
          accessible
          accessibilityRole="text"
          accessibilityLabel={
            id ? t('message.unavailableLabel') : t('message.select')
          }
          style={styles.empty}>
          <Text
            accessibilityRole="header"
            style={[styles.emptyTitle, { color: colors.foreground }]}>
            {id ? t('message.unavailable') : t('message.empty')}
          </Text>
          <Text style={[styles.emptyDescription, { color: colors.secondary }]}>
            {id ? t('message.chooseAnother') : t('message.select')}
          </Text>
        </View>
      ) : (
        <ScrollView contentContainerStyle={styles.content}>
          <Pressable
            accessibilityRole="button"
            onPress={() => {
              void actions.setUnread(message.id, !message.unread);
            }}>
            <Text style={[styles.secondary, { color: colors.accent }]}>
              {message.unread ? t('message.markRead') : t('message.markUnread')}
            </Text>
          </Pressable>
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
            {message.body}
          </Text>
        </ScrollView>
      )}
    </View>
  );
}
