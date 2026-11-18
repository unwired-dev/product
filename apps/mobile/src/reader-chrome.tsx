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

import { useBlockSender } from './block-sender.tsx';
import { usePaletteHeader } from './command-palette.tsx';
import { ContextMenu, Monogram, NavigationChrome } from './design.tsx';
import { useLocalization, useMessageDateFormat } from './localization.ts';
import { useInbox, useMailbox } from './mailbox.tsx';
import { textStyles, useLargeText, usePalette } from './theme.ts';

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
  // The sender's long-press target reaches 44pt, 2pt beyond its 40pt of text on each side, without
  // moving the text. The menu's own padding would count twice: the legacy view interop sizes the
  // native view to its padded content and mounts its children at their padded offset.
  fromText: { flex: 1, marginVertical: -2 },
  fromTarget: { paddingVertical: 2 },
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
  stacked: { flexDirection: 'column', alignItems: 'stretch' },
  stackedText: { flex: 0 },
  // Centred in the reader's 46pt leading inset, so the text keeps the body's edge.
  hangingAvatar: { position: 'absolute', left: -(40 * ipadListScale + 36) / 2 },
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
  const large = useLargeText();
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
        // The header stays put above the scrolling body, so a long subject leaves the body room.
        numberOfLines={large ? 3 : 1}
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

// At accessibility text sizes the sender, address and date stack at the full width and wrap. The
// initials would then sit alone above the sender, so only initials hanging in the inset stay.
const headerLayout = (
  large: boolean,
  hanging: boolean,
  monogram: boolean | undefined,
) =>
  large
    ? {
        stack: styles.stacked,
        text: styles.stackedText,
        lines: 0,
        summaryLines: 0,
        initials: hanging && monogram !== false,
      }
    : {
        stack: undefined,
        text: undefined,
        lines: 1,
        summaryLines: ipad ? 2 : 1,
        initials: monogram !== false,
      };

// A message's sender, address and time beside neutral initials, and its disclosed recipients.
export function MessageHeader({
  message,
  highlighted = false,
  recipients = noRecipients,
  mailbox,
  hanging = false,
  monogram,
}: {
  readonly message: Readonly<{
    id: string;
    sender: string;
    address: string;
    receivedAt: string;
  }>;
  readonly highlighted?: boolean;
  // Lines such as "To: …" and "Cc: …", once the message's headers are read.
  readonly recipients?: readonly string[];
  // The line naming the mailbox it arrived in.
  readonly mailbox?: string | undefined;
  // The initials hang in the reader's leading inset rather than indenting the text.
  readonly hanging?: boolean;
  readonly monogram?: boolean;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const dateFormat = useMessageDateFormat();
  const fullDateFormat = useMessageDateFormat(true);
  const connection = useMailbox()?.id ?? '';
  const block = useBlockSender();
  const blockItems = block.items(message.address, connection, message.id);
  const copyAddress = () => {
    void setStringAsync(message.address);
  };
  const secondary = ipad ? styles.padSecondary : styles.secondary;
  const layout = headerLayout(useLargeText(), hanging, monogram);
  return (
    <View style={[styles.from, ipad && styles.padFrom, layout.stack]}>
      {layout.initials ? (
        <View style={hanging && styles.hangingAvatar}>
          <Monogram name={message.sender} />
        </View>
      ) : null}
      <ContextMenu
        style={[ipad ? styles.padFromText : styles.fromText, layout.text]}
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
          { items: blockItems },
        ]}>
        <View style={ipad ? null : styles.fromTarget}>
          <View style={ipad ? [styles.padIdentity, layout.stack] : null}>
            <Text
              accessibilityActions={[
                { name: 'copy', label: t('contextMenu.copyAddress') },
                ...blockItems.map(({ key, title }) => ({
                  name: key,
                  label: title,
                })),
              ]}
              onAccessibilityAction={({ nativeEvent }) => {
                if (nativeEvent.actionName === 'copy') {
                  copyAddress();
                }
                for (const item of blockItems) {
                  if (item.key === nativeEvent.actionName) {
                    item.run();
                  }
                }
              }}
              accessibilityState={highlighted ? { selected: true } : undefined}
              numberOfLines={layout.lines}
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
                numberOfLines={layout.lines}
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
              numberOfLines={layout.summaryLines}
              style={[
                secondary,
                ipad && styles.padRecipients,
                { color: colors.textSecondary },
              ]}>
              {line}
            </Text>
          ))}
        </View>
      </ContextMenu>
      {block.alert}
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
