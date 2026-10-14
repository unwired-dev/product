import type { ViewProps } from 'react-native';

import { spacing } from '@private-email/mail-core/theme';
import { setStringAsync } from 'expo-clipboard';
import { createContext, useState } from 'react';
import {
  Pressable,
  requireNativeComponent,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { usePaletteHeader } from './command-palette.tsx';
import { ContextMenu, Glass, Monogram, SFSymbol } from './design.tsx';
import { useLocalization, useMessageDateFormat } from './localization.ts';
import { useInbox } from './mailbox.tsx';
import { textStyles, usePalette } from './theme.ts';

const NativeReaderChrome = requireNativeComponent<ViewProps>(
  'UnwiredReaderChrome',
);

// The compose route reports the native reading column's width to its overlay owner.
export const ReaderPaneWidthContext = createContext<
  ((width: number) => void) | undefined
>(undefined);

const styles = StyleSheet.create({
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingHorizontal: spacing.l,
    paddingVertical: spacing.xs,
  },
  headerTitle: { ...textStyles.headline, flex: 1, textAlign: 'center' },
  backGlass: { borderRadius: 22 },
  back: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    minHeight: 44,
    minWidth: 44,
    paddingLeft: 14,
    paddingRight: 10,
  },
  badge: {
    minWidth: 24,
    height: 24,
    borderRadius: 12,
    paddingHorizontal: 6,
    alignItems: 'center',
    justifyContent: 'center',
  },
  badgeText: { ...textStyles.subheadline, fontWeight: '600' },
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

// The compact reader's header: Back with the mailbox's unread count, and the subject.
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
  const [backWidth, setBackWidth] = useState(72);
  const [focused, setFocused] = useState(false);
  const unread =
    state.kind === 'ready'
      ? state.messages.filter((message) => message.unread).length
      : 0;
  return (
    <View
      style={styles.header}
      {...header.swipe}>
      <NativeReaderChrome
        style={{ position: 'absolute', width: 0, height: 0 }}
      />
      <View style={[styles.backGlass, { boxShadow: colors.smallGlassShadow }]}>
        <Glass
          cornerRadius={22}
          style={StyleSheet.absoluteFill}
        />
        <Pressable
          focusable
          onLayout={(event) => {
            setBackWidth(event.nativeEvent.layout.width);
          }}
          onFocus={() => {
            setFocused(true);
          }}
          onBlur={() => {
            setFocused(false);
          }}
          accessibilityRole="button"
          accessibilityLabel={
            unread === 0
              ? t('message.back')
              : t('message.backUnread', { count: unread })
          }
          onPress={onClose}
          style={[
            styles.back,
            {
              borderWidth: 2,
              borderColor: focused ? colors.accentInk : 'transparent',
              borderRadius: 22,
            },
          ]}>
          <SFSymbol
            name="chevron.left"
            size={16}
            color={colors.textPrimary}
          />
          {unread === 0 ? null : (
            <View
              style={[styles.badge, { backgroundColor: colors.textPrimary }]}>
              <Text
                style={[styles.badgeText, { color: colors.surfaceContent }]}>
                {unread > 99 ? '99+' : String(unread)}
              </Text>
            </View>
          )}
        </Pressable>
      </View>
      <Text
        accessibilityRole="header"
        numberOfLines={1}
        style={[styles.headerTitle, { color: colors.textPrimary }]}
        {...header.action}>
        {subject}
      </Text>
      <View style={{ width: backWidth }} />
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
