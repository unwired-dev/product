import type { ViewProps } from 'react-native';

import { spacing } from '@private-email/mail-core/theme';
import { setStringAsync } from 'expo-clipboard';
import { createContext, use } from 'react';
import { StyleSheet, Text, View } from 'react-native';

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
});

// The compact reader's header: the subject beneath the navigation bar, whose system Back shows the
// mailbox's unread count.
export function ReaderHeader({
  subject,
  onClose,
}: {
  readonly subject: string;
  readonly onClose: () => void;
}) {
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
        onPop={onClose}
        backLabel={
          unread === 0
            ? t('message.back')
            : t('message.backUnread', { count: unread })
        }
        backCount={unread === 0 ? '' : count}
        surface={colors.surfaceContent}
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

// A message's sender, address and time beside neutral initials.
export function MessageHeader({
  message,
  highlighted = false,
}: {
  readonly message: Readonly<{
    sender: string;
    address: string;
    receivedAt: string;
  }>;
  readonly highlighted?: boolean;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const dateFormat = useMessageDateFormat();
  const fullDateFormat = useMessageDateFormat(true);
  const copyAddress = () => {
    void setStringAsync(message.address);
  };
  return (
    <View style={styles.from}>
      <Monogram name={message.sender} />
      <ContextMenu
        style={styles.fromText}
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
          style={[styles.sender, { color: colors.textPrimary }]}>
          {message.sender}
        </Text>
        <Text
          numberOfLines={1}
          style={[styles.secondary, { color: colors.textSecondary }]}>
          {message.address}
        </Text>
      </ContextMenu>
      <Text
        accessibilityLabel={t('message.received', {
          date: fullDateFormat.format(new Date(message.receivedAt)),
        })}
        style={[styles.secondary, { color: colors.textSecondary }]}>
        {t('message.received', {
          date: dateFormat.format(new Date(message.receivedAt)),
        })}
      </Text>
    </View>
  );
}
