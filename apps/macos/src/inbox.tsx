import type { Message } from '@private-email/mail-core';

import { spacing } from '@private-email/mail-core/theme';
import { useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { useInbox, useInboxActions } from './mailbox.ts';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  fill: { flex: 1 },
  heading: { padding: spacing.large, paddingBottom: spacing.medium },
  title: { fontSize: 34, fontWeight: '700', letterSpacing: -0.8 },
  subtitle: { fontSize: 14, marginTop: 4 },
  list: { paddingHorizontal: spacing.small, gap: 4 },
  row: {
    minHeight: 116,
    padding: 14,
    borderWidth: 2,
    borderRadius: 12,
    borderCurve: 'continuous',
  },
  rowHeading: {
    flexDirection: 'row',
    alignItems: 'baseline',
    gap: spacing.small,
  },
  sender: { flex: 1, fontSize: 16, fontWeight: '600' },
  date: { fontSize: 12 },
  subjectLine: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    marginTop: 5,
  },
  subject: { flex: 1, fontSize: 15, fontWeight: '500' },
  unread: { width: 6, height: 6, borderRadius: 3 },
  preview: { fontSize: 14, lineHeight: 20, marginTop: 5 },
  footer: { fontSize: 12, padding: spacing.large },
  notice: { padding: spacing.large, fontSize: 16 },
});

interface InboxProps {
  readonly selectedId: string | undefined;
  readonly onSelect: (id: string) => void;
}

const dateFormat = new Intl.DateTimeFormat('en', {
  month: 'short',
  day: 'numeric',
  timeZone: 'UTC',
});

function MessageRow({
  message,
  selected,
  onSelect,
}: {
  readonly message: Message;
  readonly selected: boolean;
  readonly onSelect: (id: string) => void;
}) {
  const colors = usePalette();
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      accessibilityLabel={`${message.unread ? 'Unread. ' : ''}${message.sender}. ${message.subject}`}
      accessibilityRole="button"
      accessibilityState={{ selected }}
      focusable
      onBlur={() => {
        setFocused(false);
      }}
      onFocus={() => {
        setFocused(true);
      }}
      onPress={() => {
        onSelect(message.id);
      }}
      style={({ pressed }) => [
        styles.row,
        {
          backgroundColor:
            selected || pressed ? colors.selected : colors.sidebar,
          borderColor: focused ? colors.accent : 'transparent',
        },
      ]}>
      <View style={styles.rowHeading}>
        <Text
          style={[styles.sender, { color: colors.foreground }]}
          numberOfLines={1}>
          {message.sender}
        </Text>
        <Text style={[styles.date, { color: colors.secondary }]}>
          {dateFormat.format(new Date(message.receivedAt))}
        </Text>
      </View>
      <View style={styles.subjectLine}>
        {message.unread ? (
          <View style={[styles.unread, { backgroundColor: colors.accent }]} />
        ) : null}
        <Text
          style={[styles.subject, { color: colors.foreground }]}
          numberOfLines={1}>
          {message.subject}
        </Text>
      </View>
      <Text
        style={[styles.preview, { color: colors.secondary }]}
        numberOfLines={2}>
        {message.preview}
      </Text>
    </Pressable>
  );
}

export function Inbox({ selectedId, onSelect }: InboxProps) {
  const state = useInbox();
  const actions = useInboxActions();
  const colors = usePalette();
  return (
    <View style={styles.fill}>
      <View style={[styles.fill, { backgroundColor: colors.sidebar }]}>
        <View
          accessible
          accessibilityRole="header"
          accessibilityLabel="Inbox. Preview mailbox"
          style={styles.heading}>
          <Text
            accessibilityRole="header"
            style={[styles.title, { color: colors.foreground }]}>
            Inbox
          </Text>
          <Text style={[styles.subtitle, { color: colors.secondary }]}>
            Preview mailbox
          </Text>
        </View>
        {state.kind === 'loading' ? (
          <ActivityIndicator accessibilityLabel="Loading Inbox" />
        ) : null}
        {state.kind === 'failed' || state.kind === 'locked' ? (
          <Text
            accessibilityRole="alert"
            style={[styles.notice, { color: colors.foreground }]}>
            {state.kind === 'locked'
              ? 'Private storage is locked. Unlock your device and try again.'
              : 'Private storage could not be opened or saved. Your stored data has been kept.'}
          </Text>
        ) : null}
        {state.kind === 'failed' || state.kind === 'locked' ? (
          <Pressable
            accessibilityRole="button"
            onPress={() => {
              void actions.load();
            }}>
            <Text style={[styles.notice, { color: colors.accent }]}>
              Try again
            </Text>
          </Pressable>
        ) : null}
        {state.kind === 'ready' ? (
          <FlatList
            accessibilityLabel="Inbox messages"
            contentContainerStyle={styles.list}
            data={state.messages}
            extraData={selectedId}
            keyExtractor={(message) => message.id}
            ListEmptyComponent={
              <Text style={[styles.notice, { color: colors.secondary }]}>
                Your inbox is clear.
              </Text>
            }
            renderItem={({ item }) => (
              <MessageRow
                message={item}
                onSelect={onSelect}
                selected={item.id === selectedId}
              />
            )}
          />
        ) : null}
        <Text style={[styles.footer, { color: colors.secondary }]}>
          Sample messages · Encrypted on this device
        </Text>
      </View>
    </View>
  );
}
