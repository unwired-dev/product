import type { ResponseKind } from '@private-email/mail-core/responses';

import { radius, spacing } from '@private-email/mail-core/theme';
import { useState } from 'react';
import {
  Animated,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  useWindowDimensions,
  View,
} from 'react-native';

import { Glass, Monogram, SFSymbol, useMenuMotion } from './design.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

const replySheetWidth = 500;
const responseIcons = {
  reply: 'arrowshape.turn.up.left',
  replyAll: 'arrowshape.turn.up.left.2',
  forward: 'arrowshape.turn.up.right',
} as const;

const styles = StyleSheet.create({
  // iPhone's Reply sheet floats inside the screen edges and grows out of the Reply button.
  replyBackdrop: { flex: 1, justifyContent: 'flex-end', padding: spacing.s },
  replySheet: {
    width: '100%',
    maxWidth: replySheetWidth,
    maxHeight: '100%',
    alignSelf: 'center',
    borderRadius: radius.sheet,
    borderCurve: 'continuous',
  },
  replyContent: { gap: spacing.l, padding: spacing.l },
  replyHeader: { flexDirection: 'row', alignItems: 'center', gap: spacing.m },
  replyFrom: { flex: 1 },
  replySender: { ...textStyles.headline },
  replyClose: {
    width: 44,
    height: 44,
    borderRadius: 22,
    borderWidth: 2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  replyTiles: { flexDirection: 'row', gap: spacing.s },
  replyTile: {
    flex: 1,
    minHeight: 64,
    gap: spacing.xs,
    paddingHorizontal: spacing.xs,
    paddingVertical: spacing.s,
    borderRadius: radius.insetGroup,
    borderCurve: 'continuous',
    borderWidth: 2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  replyLabel: { ...textStyles.subheadline, textAlign: 'center' },
  secondary: { ...textStyles.footnote },
});

// Owns the Reply presentation while the reader owns response preparation.
export function ReplySheet({
  open,
  origin,
  message,
  onResponse,
  onClose,
}: {
  readonly open: boolean;
  readonly origin: number;
  readonly message: Readonly<{ sender: string; preview: string }>;
  readonly onResponse: (kind: ResponseKind) => void;
  readonly onClose: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [focused, setFocused] = useState<string>();
  const { width } = useWindowDimensions();
  const sheetWidth = Math.min(width - 2 * spacing.s, replySheetWidth);
  const motion = useMenuMotion(open, 'grow');
  if (!motion.shown) {
    return null;
  }
  return (
    <Modal
      visible
      transparent
      animationType="none"
      onRequestClose={onClose}
      supportedOrientations={[
        'portrait',
        'portrait-upside-down',
        'landscape-left',
        'landscape-right',
      ]}>
      <View
        accessibilityElementsHidden={!open}
        pointerEvents={open ? 'auto' : 'none'}
        style={styles.replyBackdrop}>
        <Animated.View
          style={[
            StyleSheet.absoluteFill,
            { backgroundColor: colors.scrimTouch },
            motion.backdropStyle,
          ]}
        />
        <Pressable
          accessible={false}
          onPress={onClose}
          style={StyleSheet.absoluteFill}
        />
        <Animated.View
          accessibilityViewIsModal
          onAccessibilityEscape={onClose}
          style={[
            styles.replySheet,
            motion.style,
            {
              boxShadow: colors.menuGlassShadow,
              backgroundColor: colors.surfaceContent,
              // The sheet grows out of where Reply was pressed.
              transformOrigin: `${Math.max(0, origin - (width - sheetWidth) / 2)}px 100%`,
            },
          ]}>
          <Glass
            cornerRadius={radius.sheet}
            style={StyleSheet.absoluteFill}
          />
          <ScrollView
            style={{ flexGrow: 0 }}
            contentContainerStyle={styles.replyContent}>
            <View style={styles.replyHeader}>
              <Monogram name={message.sender} />
              <View style={styles.replyFrom}>
                <Text
                  numberOfLines={1}
                  style={[styles.replySender, { color: colors.textPrimary }]}>
                  {message.sender}
                </Text>
                <Text
                  numberOfLines={1}
                  style={[styles.secondary, { color: colors.textSecondary }]}>
                  {message.preview}
                </Text>
              </View>
              <Pressable
                accessibilityRole="button"
                accessibilityLabel={t('message.closeResponses')}
                onFocus={() => {
                  setFocused('close');
                }}
                onBlur={() => {
                  setFocused(undefined);
                }}
                onPress={onClose}
                style={({ pressed }) => [
                  styles.replyClose,
                  {
                    backgroundColor: pressed
                      ? colors.accentSelectionSubtle
                      : colors.fillQuiet,
                    borderColor:
                      focused === 'close' ? colors.accentInk : 'transparent',
                  },
                ]}>
                <SFSymbol
                  name="xmark"
                  color={colors.textPrimary}
                />
              </Pressable>
            </View>
            <View style={styles.replyTiles}>
              {(['reply', 'replyAll', 'forward'] as const).map((kind) => (
                <Pressable
                  key={kind}
                  accessibilityRole="button"
                  accessibilityLabel={t(`message.${kind}`)}
                  onFocus={() => {
                    setFocused(kind);
                  }}
                  onBlur={() => {
                    setFocused(undefined);
                  }}
                  onPress={() => {
                    onClose();
                    onResponse(kind);
                  }}
                  style={({ pressed }) => [
                    styles.replyTile,
                    {
                      backgroundColor: pressed
                        ? colors.accentSelectionSubtle
                        : colors.fillQuiet,
                      borderColor:
                        focused === kind ? colors.accentInk : 'transparent',
                    },
                  ]}>
                  <SFSymbol
                    name={responseIcons[kind]}
                    size={22}
                    color={colors.textPrimary}
                  />
                  <Text
                    style={[styles.replyLabel, { color: colors.textPrimary }]}>
                    {t(`message.${kind}`)}
                  </Text>
                </Pressable>
              ))}
            </View>
          </ScrollView>
        </Animated.View>
      </View>
    </Modal>
  );
}
