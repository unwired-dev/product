import type { ResponseKind } from '@private-email/mail-core/responses';

import { radius, spacing } from '@private-email/mail-core/theme';
import { createContext, Fragment, use, useLayoutEffect, useState } from 'react';
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

// One of the Thread's organizing actions, as the iPhone Reply sheet lists it: Archive joins the
// response tiles; the rest are rows grouped by what they change.
export type ThreadAction = Readonly<{
  name: string;
  label: string;
  icon: string;
  group: 'tile' | 'state' | 'place';
  // Where the sheet was opened, so a picker the action opens can grow from the same place.
  run: (origin: number) => void;
}>;

// The reader toolbar offers its organizing actions to an iPhone Reply sheet. A sheet that hosts
// them claims them, and the toolbar then drops its own More menu.
export const ThreadActionsContext = createContext<
  | Readonly<{ actions: readonly ThreadAction[]; claim: () => () => void }>
  | undefined
>(undefined);
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
  actionGroup: {
    overflow: 'hidden',
    borderRadius: radius.insetGroup,
    borderCurve: 'continuous',
  },
  actionRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    minHeight: 48,
    // The focus border counts toward the row's 16pt horizontal and 12pt vertical insets.
    paddingHorizontal: spacing.l - 2,
    paddingVertical: spacing.m - 2,
    borderWidth: 2,
    borderRadius: radius.insetGroup,
  },
  actionLabel: { ...textStyles.body, flex: 1 },
  actionSeparator: {
    height: StyleSheet.hairlineWidth,
    marginHorizontal: spacing.l,
  },
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
  const thread = use(ThreadActionsContext);
  const claim = thread?.claim;
  useLayoutEffect(() => claim?.(), [claim]);
  const actions = thread?.actions ?? [];
  const tiles = [
    ...(['reply', 'replyAll', 'forward'] as const).map((kind) => ({
      name: kind,
      label: t(`message.${kind}`),
      icon: responseIcons[kind],
      run: () => {
        onResponse(kind);
      },
    })),
    ...actions.filter(({ group }) => group === 'tile'),
  ];
  const groups = (['state', 'place'] as const)
    .map((group) => actions.filter((action) => action.group === group))
    .filter((group) => group.length > 0);
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
              {tiles.map(({ name, label, icon, run }) => (
                <Pressable
                  key={name}
                  accessibilityRole="button"
                  accessibilityLabel={label}
                  onFocus={() => {
                    setFocused(name);
                  }}
                  onBlur={() => {
                    setFocused(undefined);
                  }}
                  onPress={() => {
                    onClose();
                    run(origin);
                  }}
                  style={({ pressed }) => [
                    styles.replyTile,
                    {
                      backgroundColor: pressed
                        ? colors.accentSelectionSubtle
                        : colors.fillQuiet,
                      borderColor:
                        focused === name ? colors.accentInk : 'transparent',
                    },
                  ]}>
                  <SFSymbol
                    name={icon}
                    size={22}
                    color={colors.textPrimary}
                  />
                  <Text
                    style={[styles.replyLabel, { color: colors.textPrimary }]}>
                    {label}
                  </Text>
                </Pressable>
              ))}
            </View>
            {groups.map((group) => (
              <View
                key={group[0]?.group}
                style={[
                  styles.actionGroup,
                  { backgroundColor: colors.fillQuiet },
                ]}>
                {group.map(({ name, label, icon, run }, index) => (
                  <Fragment key={name}>
                    {index === 0 ? null : (
                      <View
                        style={[
                          styles.actionSeparator,
                          { backgroundColor: colors.separator },
                        ]}
                      />
                    )}
                    <Pressable
                      accessibilityRole="button"
                      accessibilityLabel={label}
                      onFocus={() => {
                        setFocused(name);
                      }}
                      onBlur={() => {
                        setFocused(undefined);
                      }}
                      onPress={() => {
                        onClose();
                        run(origin);
                      }}
                      style={({ pressed }) => [
                        styles.actionRow,
                        {
                          backgroundColor: pressed
                            ? colors.accentSelectionSubtle
                            : 'transparent',
                          borderColor:
                            focused === name ? colors.accentInk : 'transparent',
                        },
                      ]}>
                      <Text
                        style={[
                          styles.actionLabel,
                          { color: colors.textPrimary },
                        ]}>
                        {label}
                      </Text>
                      <SFSymbol
                        name={icon}
                        size={20}
                        color={colors.textPrimary}
                      />
                    </Pressable>
                  </Fragment>
                ))}
              </View>
            ))}
          </ScrollView>
        </Animated.View>
      </View>
    </Modal>
  );
}
