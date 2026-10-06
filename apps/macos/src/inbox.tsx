import type { Message } from '@private-email/mail-core';
import type { GmailAction } from '@private-email/mail-core/gmail-actions';
import type { GmailMessage } from '@private-email/mail-core/gmail-inbox';

import {
  quickActions,
  restoreAfter,
} from '@private-email/mail-core/gmail-actions';
import { gmailSyncCopy } from '@private-email/mail-core/gmail-inbox';
import { spacing } from '@private-email/mail-core/theme';
import { useContext, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { useInbox, useInboxActions } from './mailbox.ts';
import { OrganizeStatus } from './organize.tsx';
import { AccountContext } from './registration-gate.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  fill: { flex: 1 },
  headingRow: { flexDirection: 'row', alignItems: 'flex-start' },
  heading: { flex: 1, padding: spacing.large, paddingBottom: spacing.medium },
  account: { fontSize: 15, padding: spacing.large },
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
  // Closes the reader when a row action takes its message out of the Inbox.
  readonly onClose?: (() => void) | undefined;
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
  onOrganize,
}: {
  readonly message: Message | GmailMessage;
  readonly selected: boolean;
  readonly onSelect: (id: string) => void;
  // Present when the message can be organized in Gmail.
  readonly onOrganize?:
    | ((message: GmailMessage, action: GmailAction) => void)
    | undefined;
}) {
  const colors = usePalette();
  const [focused, setFocused] = useState(false);
  const organizing =
    onOrganize !== undefined && 'threadId' in message
      ? quickActions(message)
      : [];
  return (
    <Pressable
      accessibilityActions={organizing.map(({ name, label }) => ({
        name,
        label,
      }))}
      accessibilityLabel={`${message.unread ? 'Unread. ' : ''}${message.sender}. ${message.subject}`}
      accessibilityRole="button"
      accessibilityState={{ selected }}
      focusable
      onAccessibilityAction={({ nativeEvent }) => {
        const chosen = organizing.find(
          ({ name }) => name === nativeEvent.actionName,
        );
        if (chosen !== undefined && 'threadId' in message) {
          onOrganize?.(message, chosen.action);
        }
      }}
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

// Synchronization keeps the cached list visible and says why Gmail may be behind.
function SyncNotice() {
  const state = useInbox();
  const actions = useInboxActions();
  const account = useContext(AccountContext);
  const colors = usePalette();
  if (state.kind !== 'ready' || !('sync' in state)) {
    return null;
  }
  // Synchronizes again once Gmail access is authorized.
  const handleAllowGmail = async (authorize: () => Promise<void>) => {
    await authorize();
    await actions.load();
  };
  const notice = gmailSyncCopy[state.sync];
  if (notice === undefined) {
    return null;
  }
  return (
    <>
      <View
        accessible
        accessibilityLabel={notice}
        accessibilityLiveRegion="polite">
        <Text style={[styles.footer, { color: colors.secondary }]}>
          {notice}
        </Text>
      </View>
      {state.sync === 'authentication' && account !== undefined ? (
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Allow Gmail access"
          onPress={() => {
            void handleAllowGmail(account.authorizeGmail);
          }}>
          <Text style={[styles.notice, { color: colors.accent }]}>
            Allow Gmail access
          </Text>
        </Pressable>
      ) : null}
      {state.sync === 'retry' ? (
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Try again"
          onPress={() => {
            void (account === undefined
              ? actions.load()
              : account.refreshInbox(actions.load));
          }}>
          <Text style={[styles.notice, { color: colors.accent }]}>
            Try again
          </Text>
        </Pressable>
      ) : null}
    </>
  );
}

export function Inbox({ selectedId, onSelect, onClose }: InboxProps) {
  const state = useInbox();
  const actions = useInboxActions();
  const account = useContext(AccountContext);
  const colors = usePalette();
  const gmail = state.kind === 'ready' && 'sync' in state;
  const mailbox = gmail ? (state.address ?? 'Gmail') : 'Preview mailbox';
  const organize =
    gmail && state.organize && 'organize' in actions
      ? (message: GmailMessage, action: GmailAction) => {
          if (message.id === selectedId && restoreAfter(action) !== undefined) {
            onClose?.();
          }
          void actions.organize(message, action);
        }
      : undefined;
  return (
    <View style={styles.fill}>
      <View style={[styles.fill, { backgroundColor: colors.sidebar }]}>
        <View style={styles.headingRow}>
          <View
            accessible
            accessibilityRole="header"
            accessibilityLabel={`Inbox. ${mailbox}`}
            style={styles.heading}>
            <Text
              accessibilityRole="header"
              style={[styles.title, { color: colors.foreground }]}>
              Inbox
            </Text>
            <Text style={[styles.subtitle, { color: colors.secondary }]}>
              {mailbox}
            </Text>
          </View>
          {account === undefined ? null : (
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="Account"
              onPress={() => {
                account.openAccount();
              }}>
              <Text style={[styles.account, { color: colors.accent }]}>
                Account
              </Text>
            </Pressable>
          )}
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
        <SyncNotice />
        <OrganizeStatus />
        {state.kind === 'ready' ? (
          <FlatList<Message | GmailMessage>
            accessibilityLabel="Inbox messages"
            contentContainerStyle={styles.list}
            data={state.messages}
            extraData={selectedId}
            keyExtractor={(message) => message.id}
            ListEmptyComponent={
              gmail && state.sync === 'syncing' ? (
                <ActivityIndicator accessibilityLabel="Loading Inbox" />
              ) : (
                <Text style={[styles.notice, { color: colors.secondary }]}>
                  Your inbox is clear.
                </Text>
              )
            }
            renderItem={({ item }) => (
              <MessageRow
                message={item}
                onOrganize={organize}
                onSelect={onSelect}
                selected={item.id === selectedId}
              />
            )}
          />
        ) : null}
        <Text style={[styles.footer, { color: colors.secondary }]}>
          {gmail
            ? 'Gmail · Encrypted on this device'
            : 'Sample messages · Encrypted on this device'}
        </Text>
      </View>
    </View>
  );
}
