import type { Message } from '@private-email/mail-core';
import type { GmailMessage } from '@private-email/mail-core/gmail-inbox';
import type { ImapMessage } from '@private-email/mail-core/imap-inbox';
import type { ReactNode } from 'react';

import { messageDay } from '@private-email/localization';
import { rowContextMenu } from '@private-email/mail-core/context-menu';
import { matchedRanges } from '@private-email/mail-core/mailboxes';
import { useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { ContextMenu, SFSymbol } from './design.tsx';
import { styles } from './inbox-styles.ts';
import {
  useLocalization,
  useMessageDateFormat,
  useMessageListDateFormats,
} from './localization.ts';
import { usePalette } from './theme.ts';

// A row's organizing action at its provider.
export type RowAction = Readonly<{
  name: string;
  label: string;
  run: () => void;
}>;
const noActions: readonly RowAction[] = [];

// A field with the search's matched words in bold.
function Marked({
  text,
  query,
}: {
  readonly text: string;
  readonly query: string | undefined;
}) {
  if (query === undefined) {
    return text;
  }
  const parts: ReactNode[] = [];
  let at = 0;
  for (const [start, end] of matchedRanges(text, query)) {
    parts.push(
      text.slice(at, start),
      <Text
        key={start}
        style={styles.match}>
        {text.slice(start, end)}
      </Text>,
    );
    at = end;
  }
  parts.push(text.slice(at));
  return parts;
}

export function MessageRow({
  message,
  mailbox,
  status,
  selected,
  onSelect,
  actions = noActions,
  now,
  query,
}: {
  readonly message: Message | GmailMessage | ImapMessage;
  // Shown when the Inbox holds more than one mailbox.
  readonly mailbox: string | undefined;
  // Whether a search result's body is saved on this device, once known.
  readonly status: string | undefined;
  readonly selected: boolean;
  readonly onSelect: () => void;
  // The organizing actions its provider offers, as accessibility actions.
  readonly actions?: readonly RowAction[] | undefined;
  // When the list was last read, which names the day the message arrived.
  readonly now: number;
  // The search that listed it, whose matched words the sender and subject mark.
  readonly query?: string | undefined;
}) {
  const colors = usePalette();
  const primaryColor = selected ? colors.accentOnFill : colors.textPrimary;
  const secondaryColor = selected ? colors.accentOnFill : colors.textSecondary;
  const focusColor = selected ? colors.accentOnFill : colors.accentInk;
  const { t } = useLocalization();
  const time = useMessageTime(message.receivedAt, now);
  const [focused, setFocused] = useState(false);
  // Gmail's star is the list's flag; other providers list none yet.
  const flagged =
    'labels' in message &&
    message.labels !== undefined &&
    message.labels.includes('STARRED');
  const label = t('inbox.rowLabel', {
    context: [
      flagged ? 'flagged' : undefined,
      mailbox === undefined ? undefined : 'mailbox',
      status === undefined ? undefined : 'status',
    ]
      .filter((part) => part !== undefined)
      .join('_'),
    row: t(message.unread ? 'inbox.unreadRow' : 'inbox.row', {
      sender: message.sender,
      subject: message.subject,
    }),
    mailbox,
    status,
  });
  return (
    <ContextMenu sections={rowContextMenu(t, message.id, actions)}>
      <Pressable
        accessibilityActions={actions.map(({ name, label: actionLabel }) => ({
          name,
          label: actionLabel,
        }))}
        accessibilityLabel={label}
        accessibilityRole="button"
        accessibilityState={{ selected }}
        focusable
        onAccessibilityAction={({ nativeEvent }) => {
          actions.find(({ name }) => name === nativeEvent.actionName)?.run();
        }}
        onBlur={() => {
          setFocused(false);
        }}
        onFocus={() => {
          setFocused(true);
        }}
        onPress={onSelect}
        style={({ pressed }) => [
          styles.row,
          {
            backgroundColor: pressed
              ? colors.accentSelectionSubtle
              : 'transparent',
            borderColor: focused ? focusColor : 'transparent',
          },
          selected && { backgroundColor: colors.accentFill },
        ]}>
        {({ pressed }) => (
          <>
            <View style={styles.rowHeading}>
              <Text
                style={[
                  styles.sender,
                  {
                    color: primaryColor,
                    fontWeight: message.unread ? '600' : '400',
                  },
                ]}
                numberOfLines={1}>
                <Marked
                  text={message.sender}
                  query={query}
                />
              </Text>
              {flagged ? (
                <SFSymbol
                  name="flag.fill"
                  size={13}
                  color={selected ? colors.accentOnFill : colors.statusWarning}
                />
              ) : null}
              <Text
                numberOfLines={1}
                style={[styles.date, { color: secondaryColor }]}>
                {time}
              </Text>
            </View>
            <Text
              style={[
                styles.subject,
                {
                  color: primaryColor,
                  fontWeight: message.unread ? '600' : '400',
                },
              ]}
              numberOfLines={1}>
              <Marked
                text={message.subject}
                query={query}
              />
            </Text>
            <Text
              style={[styles.preview, { color: secondaryColor }]}
              numberOfLines={1}>
              {message.preview}
            </Text>
            {mailbox === undefined ? null : (
              <Text
                numberOfLines={1}
                style={[styles.mailbox, { color: secondaryColor }]}>
                {t('inbox.inMailbox', { mailbox })}
              </Text>
            )}
            {status === undefined ? null : (
              <Text
                numberOfLines={1}
                style={[styles.mailbox, { color: secondaryColor }]}>
                {status}
              </Text>
            )}
            {message.unread ? (
              <View
                style={[
                  styles.unread,
                  {
                    backgroundColor: pressed
                      ? colors.accentInk
                      : colors.accentFill,
                  },
                  selected && { backgroundColor: colors.accentOnFill },
                ]}
              />
            ) : null}
            {selected ? null : (
              <View
                style={[
                  styles.separator,
                  { backgroundColor: colors.separator },
                ]}
              />
            )}
          </>
        )}
      </Pressable>
    </ContextMenu>
  );
}

// A row's time: the clock today, the day's name within the last week, the date before that.
function useMessageTime(receivedAt: string, now: number) {
  const { t } = useLocalization();
  const formats = useMessageListDateFormats();
  const dateFormat = useMessageDateFormat();
  const received = new Date(receivedAt);
  const day = messageDay(receivedAt, now);
  if (day === 'today') {
    return formats.time.format(received);
  }
  if (day === 'yesterday') {
    return t('inbox.yesterday');
  }
  return day === 'lastWeek'
    ? formats.weekday.format(received)
    : dateFormat.format(received);
}

// Rows are grouped under the day they arrived.
export function DateDivider({
  receivedAt,
  now,
}: {
  readonly receivedAt: string;
  readonly now: number;
}) {
  const { t } = useLocalization();
  const formats = useMessageListDateFormats();
  const day = messageDay(receivedAt, now);
  const label =
    day === 'earlier'
      ? formats.month(new Date(receivedAt), now)
      : t(`inbox.${day}`);
  const colors = usePalette();
  return (
    <View
      accessible
      accessibilityRole="header"
      accessibilityLabel={label}
      style={styles.divider}>
      <View
        style={[styles.dividerLine, { backgroundColor: colors.separator }]}
      />
      <Text style={[styles.dividerLabel, { color: colors.textSecondary }]}>
        {label}
      </Text>
      <View
        style={[styles.dividerLine, { backgroundColor: colors.separator }]}
      />
    </View>
  );
}

// Rows still arriving from the mail server.
export function SkeletonRows() {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <View
      accessible
      accessibilityLabel={t('inbox.loading')}
      accessibilityRole="progressbar">
      {[0, 1, 2].map((row) => (
        <View
          key={row}
          style={[styles.skeleton, { borderBottomColor: colors.separator }]}>
          {(['38%', '64%', '84%'] as const).map((width) => (
            <View
              key={width}
              style={[
                styles.skeletonBar,
                { width, backgroundColor: colors.fillQuiet },
              ]}
            />
          ))}
        </View>
      ))}
    </View>
  );
}
