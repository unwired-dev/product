import type { ViewProps } from 'react-native';

import {
  ipadListScale,
  palette,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
import { setStringAsync } from 'expo-clipboard';
import { createContext, use } from 'react';
import {
  DynamicColorIOS as dynamicColorIOS,
  Platform,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { usePaletteHeader } from './command-palette.tsx';
import { ContextMenu, Monogram, NavigationChrome } from './design.tsx';
import { useLocalization, useMessageDateFormat } from './localization.ts';
import { useInbox } from './mailbox.tsx';
import { textStyles, usePalette } from './theme.ts';

// Every reading-column route reports the native column's width to the shell, which sizes the
// window bar's edge and the composer overlay from it.
export const ReaderPaneWidthContext = createContext<
  ((width: number) => void) | undefined
>(undefined);

export function ReaderPane({ children, ...props }: ViewProps) {
  const onWidth = use(ReaderPaneWidthContext);
  return (
    <View
      testID="reader-pane"
      {...props}
      onLayout={({ nativeEvent }) => {
        onWidth?.(nativeEvent.layout.width);
      }}
      style={{ flex: 1 }}>
      {children}
    </View>
  );
}

// The iPad reader sets the sender and address on one line at the list's 1.15× scale, the date
// beside it and the recipients beneath, as the frames draw them.
const ipad = Platform.OS === 'ios' && Platform.isPad;

const styles = StyleSheet.create({
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    minHeight: 40,
    paddingHorizontal: spacing.l,
    paddingVertical: spacing.xs,
  },
  headerTitle: { ...textStyles.headline, flex: 1, textAlign: 'center' },
  countRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingTop: spacing.xs,
  },
  count: { ...textStyles.subheadline, flex: 1 },
  from: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  fromText: { flex: 1, minHeight: 44 },
  sender: { ...textStyles.headline },
  secondary: { ...textStyles.footnote },
  padFrom: { alignItems: 'flex-start' },
  padFromText: { flex: 1 },
  padIdentity: {
    flexDirection: 'row',
    alignItems: 'baseline',
    gap: spacing.xs * ipadListScale,
  },
  padSender: { ...typography.ipadList.body, fontWeight: '600', flexShrink: 1 },
  // A long address gives way before the sender's name.
  padAddress: { ...typography.ipadList.body, flexShrink: 3 },
  padSecondary: { ...typography.ipadList.subheadline },
  padRecipients: { marginTop: 2 * ipadListScale },
});

// The compact reader's header: the subject beneath the navigation bar, whose system Back shows the
// mailbox's unread count.
export function ReaderHeader({ subject }: { readonly subject: string }) {
  const state = useInbox();
  const header = usePaletteHeader();
  const colors = usePalette();
  const { t } = useLocalization();
  const unread =
    state.kind === 'ready'
      ? state.messages.filter((message) => message.unread).length
      : 0;
  const count = unread > 99 ? '99+' : String(unread);
  return (
    <View
      style={styles.header}
      {...header.swipe}>
      <NavigationChrome
        testID="system-back"
        backLabel={
          unread === 0
            ? t('message.back')
            : t('message.backUnread', { count: unread })
        }
        backCount={unread === 0 ? '' : count}
        surface={dynamicColorIOS({
          light: palette.light.surfaceContent,
          dark: palette.dark.surfaceContent,
        })}
      />
      <Text
        accessibilityRole="header"
        numberOfLines={1}
        style={[styles.headerTitle, { color: colors.textPrimary }]}
        {...header.action}>
        {subject}
      </Text>
    </View>
  );
}

// "N Messages" above the opened conversation.
export function MessageCount({ count }: { readonly count: number }) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <View style={styles.countRow}>
      <Text style={[styles.count, { color: colors.textSecondary }]}>
        {t('message.count', { count })}
      </Text>
    </View>
  );
}

const noRecipients: readonly string[] = [];

const summaryLines = (separate: boolean, lines: readonly string[]) =>
  separate || lines.length === 0 ? lines : [lines.join(' · ')];

// A message's sender, address and time beside neutral initials, and its disclosed recipients.
export function MessageHeader({
  message,
  highlighted = false,
  recipients = noRecipients,
  mailbox,
}: {
  readonly message: Readonly<{
    sender: string;
    address: string;
    receivedAt: string;
  }>;
  readonly highlighted?: boolean;
  // Lines such as "To: …" and "Cc: …", once the message's headers are read.
  readonly recipients?: readonly string[];
  // The line naming the mailbox it arrived in.
  readonly mailbox?: string | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const dateFormat = useMessageDateFormat();
  const fullDateFormat = useMessageDateFormat(true);
  const copyAddress = () => {
    void setStringAsync(message.address);
  };
  const secondary = ipad ? styles.padSecondary : styles.secondary;
  return (
    <View style={[styles.from, ipad && styles.padFrom]}>
      <Monogram name={message.sender} />
      <ContextMenu
        style={ipad ? styles.padFromText : styles.fromText}
        sections={[
          {
            items: [
              {
                key: `copy\n${message.address}`,
                title: t('contextMenu.copyAddress'),
                symbol: 'doc.on.doc',
                run: copyAddress,
              },
            ],
          },
        ]}>
        <View style={ipad ? styles.padIdentity : null}>
          <Text
            accessibilityActions={[
              { name: 'copy', label: t('contextMenu.copyAddress') },
            ]}
            onAccessibilityAction={({ nativeEvent }) => {
              if (nativeEvent.actionName === 'copy') {
                copyAddress();
              }
            }}
            accessibilityState={highlighted ? { selected: true } : undefined}
            numberOfLines={1}
            style={[
              ipad ? styles.padSender : styles.sender,
              { color: colors.textPrimary },
            ]}>
            {message.sender}
          </Text>
          {/* iPhone's header keeps one summary line: the recipients once read, else the address,
              which Copy Address still offers. */}
          {ipad || recipients.length === 0 ? (
            <Text
              numberOfLines={1}
              style={[
                ipad ? styles.padAddress : styles.secondary,
                { color: colors.textSecondary },
              ]}>
              {message.address}
            </Text>
          ) : null}
        </View>
        {/* iPhone's frames give the sender one summary line beneath it. */}
        {summaryLines(ipad, [
          ...recipients,
          ...(mailbox === undefined ? [] : [mailbox]),
        ]).map((line) => (
          <Text
            key={line}
            numberOfLines={ipad ? 2 : 1}
            style={[
              secondary,
              ipad && styles.padRecipients,
              { color: colors.textSecondary },
            ]}>
            {line}
          </Text>
        ))}
      </ContextMenu>
      <Text
        accessibilityLabel={t('message.received', {
          date: fullDateFormat.format(new Date(message.receivedAt)),
        })}
        style={[secondary, { color: colors.textSecondary }]}>
        {/* iPhone's compact header leaves the time zone to the spoken date. */}
        {ipad
          ? t('message.received', {
              date: dateFormat.format(new Date(message.receivedAt)),
            })
          : dateFormat.format(new Date(message.receivedAt))}
      </Text>
    </View>
  );
}
